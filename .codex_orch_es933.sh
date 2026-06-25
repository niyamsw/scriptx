#!/usr/bin/env bash
set -euo pipefail

rhel_host="9.30.211.180"
pod_host="9.30.218.20"

remote_tmux_run() {
    local host="$1" session="$2" body="$3" quoted
    printf -v quoted '%q' "$body"
    ssh "root@${host}" "tmux kill-session -t ${session} 2>/dev/null || true; tmux new-session -d -s ${session} bash -lc ${quoted}; sleep 2; tmux capture-pane -p -J -t ${session}:0 -S -500"
}

status_host() {
    local host="$1"
    remote_tmux_run "$host" es933-status '
        echo "HOST $(hostname)"
        echo "SESSIONS"
        tmux list-sessions 2>/dev/null || true
        echo "WINDOWS"
        tmux list-windows -t es933-full -F "#{window_index}:#{window_name}:#{pane_current_command}:#{pane_dead_status}" 2>/dev/null || true
        for w in rhel810 rhel96 rhel97 ubuntu2204 ubuntu2404 sles15sp7; do
            echo "WINDOW:$w"
            tmux capture-pane -p -J -t "es933-full:$w" -S -80 2>/dev/null | tail -45 || true
        done
        echo "CONTAINERS"
        if command -v docker >/dev/null 2>&1; then
            docker ps -a | grep es933 || true
        fi
        if command -v podman >/dev/null 2>&1; then
            podman ps -a | grep es933 || true
        fi
        sleep 60
    '
}

inspect_rhel810() {
    remote_tmux_run "$rhel_host" es933-inspect-rhel810 '
        echo "HOST $(hostname)"
        docker ps -a | grep es933 || true
        echo "LOGS"
        docker logs es933-rhel810 2>&1 | tail -120 || true
        echo "INSPECT_STATE"
        docker inspect es933-rhel810 2>/dev/null | grep -E "\"Status\"|\"Running\"|\"Dead\"|\"ExitCode\"|\"Error\"|\"StartedAt\"|\"FinishedAt\"|\"Path\"|\"Args\"" || true
        echo "TRY_START"
        docker start es933-rhel810 2>&1 || true
        sleep 2
        docker ps -a | grep es933-rhel810 || true
        docker logs es933-rhel810 2>&1 | tail -80 || true
        sleep 60
    '
}

inspect_pod_launch() {
    remote_tmux_run "$pod_host" es933-inspect-pod-launch '
        echo "HOST $(hostname)"
        echo "LAUNCH"
        tmux capture-pane -p -J -t es933-launch:0 -S -220 2>/dev/null | tail -180 || true
        echo "WINDOWS"
        tmux list-windows -t es933-full -F "#{window_index}:#{window_name}:#{pane_current_command}:#{pane_dead_status}" 2>/dev/null || true
        echo "CONTAINERS"
        docker ps -a | grep es933 || true
        podman ps -a | grep es933 || true
        sleep 60
    '
}

inspect_boost_patch() {
    remote_tmux_run "$pod_host" es933-inspect-boost '
        echo "HOST $(hostname)"
        for c in es933-ubuntu2204 es933-ubuntu2404; do
            echo "CONTAINER:$c"
            docker exec "$c" bash -lc '"'"'
                cd /home/test/scriptx/boost_1_86_0 2>/dev/null || cd /home/test/scriptx
                echo "prime_fmod.hpp"
                sed -n "25,48p" boost/unordered/detail/prime_fmod.hpp 2>/dev/null || true
                echo "reject"
                sed -n "1,120p" boost/unordered/detail/prime_fmod.hpp.rej 2>/dev/null || true
                echo "run markers"
                grep -R "CODEX_RUN_DONE\|Hunk #1 FAILED\|BUILD FAILED" -n /home/test/scriptx/codex-run-* 2>/dev/null | tail -40 || true
            '"'"'
        done
        sleep 60
    '
}

failure_logs() {
    remote_tmux_run "$rhel_host" es933-rhel-failures '
        echo "HOST $(hostname)"
        for c in es933-rhel810 es933-rhel96 es933-rhel97; do
            echo "CONTAINER:$c"
            docker exec "$c" bash -lc '"'"'
                cd /home/test/scriptx || exit 0
                log=$(ls -1t codex-run-*.log 2>/dev/null | head -1 || true)
                echo "LOG:$log"
                if [[ -n "$log" ]]; then
                    echo "ERRORS"
                    grep -n -iE "No match for argument|Unable to find a match|Error:|Failed|Cannot|No package|conflicting requests|Curl error|Permission denied|Docker daemon|not available|No space left|BUILD FAILED" "$log" | tail -80 || true
                    echo "TAIL"
                    tail -120 "$log"
                fi
            '"'"'
        done
        sleep 60
    '
    remote_tmux_run "$pod_host" es933-pod-failures '
        echo "HOST $(hostname)"
        echo "WINDOWS"
        tmux list-windows -t es933-full -F "#{window_index}:#{window_name}:#{pane_current_command}:#{pane_dead_status}" 2>/dev/null || true
        for c in es933-ubuntu2204 es933-ubuntu2404 es933-sles15sp7; do
            echo "CONTAINER:$c"
            docker exec "$c" bash -lc '"'"'
                cd /home/test/scriptx || exit 0
                log=$(ls -1t codex-run-*.log 2>/dev/null | head -1 || true)
                echo "LOG:$log"
                if [[ -n "$log" ]]; then
                    grep -n -iE "Hunk #1 FAILED|No match for argument|Unable to find a match|Error:|Failed|Cannot|No package|conflicting requests|Permission denied|Docker daemon|not available|No space left|BUILD FAILED|CODEX_RUN_DONE" "$log" | tail -80 || true
                    tail -60 "$log"
                fi
            '"'"'
        done
        sleep 60
    '
}

rhel_docker_probe() {
    remote_tmux_run "$rhel_host" es933-rhel-docker-probe '
        echo "HOST $(hostname)"
        for c in es933-rhel810 es933-rhel96 es933-rhel97; do
            echo "CONTAINER:$c"
            docker exec -u test "$c" bash -lc '"'"'
                echo "whoami=$(whoami) user=${USER:-}"
                command -v docker || true
                docker --version 2>&1 || true
                echo "docker info"
                docker info 2>&1 | sed -n "1,120p" || true
                echo "podman info"
                podman info 2>&1 | sed -n "1,120p" || true
                echo "groups"
                id
            '"'"'
        done
        sleep 60
    '
}

rhel_root_docker_probe() {
    remote_tmux_run "$rhel_host" es933-rhel-root-docker-probe '
        echo "HOST $(hostname)"
        for c in es933-rhel810 es933-rhel96 es933-rhel97; do
            echo "CONTAINER:$c"
            docker exec "$c" bash -lc '"'"'
                echo "whoami=$(whoami) user=${USER:-}"
                docker --version 2>&1 || true
                echo "docker info root"
                docker info 2>&1 | sed -n "1,120p" || true
                echo "podman info root"
                podman info 2>&1 | sed -n "1,120p" || true
            '"'"'
        done
        sleep 60
    '
}

rerun_rhel() {
    remote_tmux_run "$rhel_host" es933-rhel-rerun '
        set -e
        bundle=/tmp/es933-9.3.3-bundle.tgz
        for label in rhel810 rhel96 rhel97; do
            c="es933-${label}"
            echo "Syncing $c"
            if [[ -d /tmp/es933-files ]]; then
                docker exec "$c" rm -rf /home/test/scriptx/patch
                docker cp /tmp/es933-files/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
                docker cp /tmp/es933-files/patch "$c:/home/test/scriptx/patch"
                docker exec "$c" bash -lc '"'"'chown -R test:"$(id -gn test)" /home/test/scriptx/build_elasticsearch.sh /home/test/scriptx/patch && chmod +x /home/test/scriptx/build_elasticsearch.sh'"'"'
            else
                docker cp "$bundle" "$c:/tmp/es933-9.3.3-bundle.tgz"
                docker exec "$c" bash -lc '"'"'
                    set -e
                    cd /home/test/scriptx
                    tar -xzf /tmp/es933-9.3.3-bundle.tgz -C /home/test/scriptx
                    chown -R test:"$(id -gn test)" /home/test/scriptx
                    chmod +x /home/test/scriptx/build_elasticsearch.sh
                '"'"'
            fi
        done
        for label in rhel810 rhel96 rhel97; do
            cmd="cd /home/test/scriptx; run_log=codex-run-${label}-fix-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=1 at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash"
            tmux send-keys -t "es933-full:${label}" C-c C-u
            tmux send-keys -l -t "es933-full:${label}" "$cmd"
            tmux send-keys -t "es933-full:${label}" C-m
            echo "Rerun sent to $label"
        done
        sleep 60
    '
}

rhel_respawn_build() {
    remote_tmux_run "$rhel_host" es933-rhel-respawn-build '
        set -e
        for label in rhel810 rhel96 rhel97; do
            c="es933-${label}"
            cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-${label}-fix-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=1 at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
            tmux respawn-pane -k -t "es933-full:${label}" "$cmd"
            echo "Respawned $label"
        done
        sleep 60
    '
}

rerun_rhel96_clean() {
    remote_tmux_run "$rhel_host" es933-rhel96-clean-rerun '
        set -e
        c="es933-rhel96"
        if [[ ! -d /tmp/es933-files ]]; then
            echo "/tmp/es933-files is missing on the RHEL VM" >&2
            exit 1
        fi
        docker exec "$c" rm -rf /home/test/scriptx/patch /home/test/scriptx/ml-cpp /home/test/scriptx/pytorch
        docker cp /tmp/es933-files/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
        docker cp /tmp/es933-files/patch "$c:/home/test/scriptx/patch"
        docker exec "$c" bash -lc '"'"'chown -R test:"$(id -gn test)" /home/test/scriptx/build_elasticsearch.sh /home/test/scriptx/patch && chmod +x /home/test/scriptx/build_elasticsearch.sh'"'"'
        cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-rhel96-fix-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=rhel96 rerun=clone-retry at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=rhel96 status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
        tmux respawn-pane -k -t "es933-full:rhel96" "$cmd"
        echo "Clean rerun sent to rhel96"
        sleep 60
    '
}

rerun_rhel810_rhel96_clean() {
    remote_tmux_run "$rhel_host" es933-rhel810-rhel96-clean-rerun '
        set -e
        if [[ ! -d /tmp/es933-files ]]; then
            echo "/tmp/es933-files is missing on the RHEL VM" >&2
            exit 1
        fi
        for label in rhel810 rhel96; do
            c="es933-${label}"
            docker exec "$c" rm -rf /home/test/scriptx/patch /home/test/scriptx/ml-cpp /home/test/scriptx/pytorch
            docker cp /tmp/es933-files/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
            docker cp /tmp/es933-files/patch "$c:/home/test/scriptx/patch"
            docker exec "$c" bash -lc '"'"'chown -R test:"$(id -gn test)" /home/test/scriptx/build_elasticsearch.sh /home/test/scriptx/patch && chmod +x /home/test/scriptx/build_elasticsearch.sh'"'"'
            cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-${label}-fix-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=clean-common-patch at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
            tmux respawn-pane -k -t "es933-full:${label}" "$cmd"
            echo "Clean rerun sent to $label"
        done
        sleep 60
    '
}

rerun_rhel_latefix() {
    remote_tmux_run "$rhel_host" es933-rhel-latefix-rerun '
        set -e
        if [[ ! -d /tmp/es933-files ]]; then
            echo "/tmp/es933-files is missing on the RHEL VM" >&2
            exit 1
        fi
        for label in rhel810 rhel96 rhel97; do
            c="es933-${label}"
            if [[ "$label" == "rhel810" ]]; then
                docker exec "$c" rm -rf /home/test/scriptx/patch /home/test/scriptx/ml-cpp /home/test/scriptx/pytorch
            else
                docker exec "$c" rm -rf /home/test/scriptx/patch
            fi
            docker cp /tmp/es933-files/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
            docker cp /tmp/es933-files/patch "$c:/home/test/scriptx/patch"
            docker exec "$c" bash -lc '"'"'chown -R test:"$(id -gn test)" /home/test/scriptx/build_elasticsearch.sh /home/test/scriptx/patch && chmod +x /home/test/scriptx/build_elasticsearch.sh'"'"'
            cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-${label}-latefix-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=latefix at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
            tmux respawn-pane -k -t "es933-full:${label}" "$cmd"
            echo "Latefix rerun sent to $label"
        done
        sleep 60
    '
}

rerun_rhel9_runfix() {
    remote_tmux_run "$rhel_host" es933-rhel9-runfix-rerun '
        set -e
        if [[ ! -d /tmp/es933-files ]]; then
            echo "/tmp/es933-files is missing on the RHEL VM" >&2
            exit 1
        fi
        for label in rhel96 rhel97; do
            c="es933-${label}"
            docker exec "$c" rm -rf /home/test/scriptx/patch
            docker cp /tmp/es933-files/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
            docker cp /tmp/es933-files/patch "$c:/home/test/scriptx/patch"
            docker exec "$c" bash -lc '"'"'chown -R test:"$(id -gn test)" /home/test/scriptx/build_elasticsearch.sh /home/test/scriptx/patch && chmod +x /home/test/scriptx/build_elasticsearch.sh'"'"'
            cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-${label}-runfix-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=runfix at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
            tmux respawn-pane -k -t "es933-full:${label}" "$cmd"
            echo "Runfix rerun sent to $label"
        done
        sleep 60
    '
}

rerun_rhel9_networkfix() {
    remote_tmux_run "$rhel_host" es933-rhel9-networkfix-rerun '
        set -e
        if [[ ! -f /tmp/build_elasticsearch.sh ]]; then
            echo "/tmp/build_elasticsearch.sh is missing on the RHEL VM" >&2
            exit 1
        fi
        for label in rhel96 rhel97; do
            c="es933-${label}"
            docker cp /tmp/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
            docker exec "$c" bash -lc '"'"'chown test:"$(id -gn test)" /home/test/scriptx/build_elasticsearch.sh && chmod +x /home/test/scriptx/build_elasticsearch.sh'"'"'
            cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-${label}-networkfix-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=networkfix at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
            tmux respawn-pane -k -t "es933-full:${label}" "$cmd"
            echo "Networkfix rerun sent to $label"
        done
        sleep 60
    '
}

rerun_rhel97_gradlelock() {
    remote_tmux_run "$rhel_host" es933-rhel97-gradlelock-rerun '
        set -e
        if [[ ! -d /tmp/es933-files ]]; then
            echo "/tmp/es933-files is missing on the RHEL VM" >&2
            exit 1
        fi
        label="rhel97"
        c="es933-${label}"
        docker cp /tmp/es933-files/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
        docker cp /tmp/es933-files/patch/. "$c:/home/test/scriptx/patch"
        docker exec "$c" bash -lc '"'"'chmod -R a+rX /home/test/scriptx/build_elasticsearch.sh /home/test/scriptx/patch'"'"'
        cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-${label}-gradlelock-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=gradlelock at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
        tmux respawn-pane -k -t "es933-full:${label}" "$cmd"
        echo "Gradle-lock rerun sent to $label"
        sleep 60
    '
}

rerun_rhel96_gradlelock() {
    remote_tmux_run "$rhel_host" es933-rhel96-gradlelock-rerun '
        set -e
        if [[ ! -d /tmp/es933-files ]]; then
            echo "/tmp/es933-files is missing on the RHEL VM" >&2
            exit 1
        fi
        label="rhel96"
        c="es933-${label}"
        docker cp /tmp/es933-files/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
        docker cp /tmp/es933-files/patch/. "$c:/home/test/scriptx/patch"
        docker exec "$c" bash -lc '"'"'chmod -R a+rX /home/test/scriptx/build_elasticsearch.sh /home/test/scriptx/patch'"'"'
        cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-${label}-gradlelock-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=gradlelock at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
        tmux respawn-pane -k -t "es933-full:${label}" "$cmd"
        echo "Gradle-lock rerun sent to $label"
        sleep 60
    '
}

rerun_rhel810_mlcppdl() {
    remote_tmux_run "$rhel_host" es933-rhel810-mlcppdl-rerun '
        set -e
        if [[ ! -d /tmp/es933-files ]]; then
            echo "/tmp/es933-files is missing on the RHEL VM" >&2
            exit 1
        fi
        label="rhel810"
        c="es933-${label}"
        docker cp /tmp/es933-files/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
        docker cp /tmp/es933-files/patch/. "$c:/home/test/scriptx/patch"
        docker exec "$c" bash -lc '"'"'chmod -R a+rX /home/test/scriptx/build_elasticsearch.sh /home/test/scriptx/patch'"'"'
        cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-${label}-mlcppdl-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=mlcppdl at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
        tmux respawn-pane -k -t "es933-full:${label}" "$cmd"
        echo "ml-cpp dl rerun sent to $label"
        sleep 60
    '
}

rhel810_compile_failure() {
    remote_tmux_run "$rhel_host" es933-rhel810-compile-failure '
        echo "HOST $(hostname)"
        docker exec es933-rhel810 bash -lc '"'"'
            cd /home/test/scriptx || exit 0
            log=$(ls -1t codex-run-rhel810-*.log 2>/dev/null | head -1 || true)
            echo "LOG:$log"
            if [[ -n "$log" ]]; then
                echo "MATCHES"
                grep -n -iE "undefined reference|collect2: error|ld:|cmake error|error:|BUILD FAILED|FAILED|Execution failed" "$log" | tail -120 || true
                echo "TAIL"
                tail -180 "$log"
            fi
        '"'"'
        sleep 60
    '
}

pod_failure_logs() {
    remote_tmux_run "$pod_host" es933-pod-failures-only '
        echo "HOST $(hostname)"
        echo "WINDOWS"
        tmux list-windows -t es933-full -F "#{window_index}:#{window_name}:#{pane_current_command}:#{pane_dead_status}" 2>/dev/null || true
        for c in es933-ubuntu2404 es933-sles15sp7; do
            echo "CONTAINER:$c"
            docker exec "$c" bash -lc '"'"'
                cd /home/test/scriptx || exit 0
                log=$(ls -1t codex-run-*.log 2>/dev/null | head -1 || true)
                echo "LOG:$log"
                if [[ -n "$log" ]]; then
                    grep -n -iE "No match for argument|Unable to find a match|Error:|Failed|Cannot|No package|conflicting requests|Permission denied|Docker daemon|not available|No space left|BUILD FAILED|Execution failed|CODEX_RUN_DONE" "$log" | tail -120 || true
                    tail -120 "$log"
                fi
            '"'"'
        done
        sleep 60
    '
}

rerun_pod_latefix() {
    remote_tmux_run "$pod_host" es933-pod-latefix-rerun '
        set -e
        if [[ ! -d /tmp/es933-files ]]; then
            echo "/tmp/es933-files is missing on the Ubuntu/SLES VM" >&2
            exit 1
        fi
        for label in ubuntu2204 ubuntu2404 sles15sp7; do
            c="es933-${label}"
            docker exec "$c" rm -rf /home/test/scriptx/patch
            docker cp /tmp/es933-files/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
            docker cp /tmp/es933-files/patch "$c:/home/test/scriptx/patch"
            docker exec "$c" bash -lc '"'"'chown -R test:"$(id -gn test)" /home/test/scriptx/build_elasticsearch.sh /home/test/scriptx/patch && chmod +x /home/test/scriptx/build_elasticsearch.sh'"'"'
            cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-${label}-latefix-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=latefix at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
            tmux respawn-pane -k -t "es933-full:${label}" "$cmd"
            echo "Latefix rerun sent to $label"
        done
        sleep 60
    '
}

rerun_ubuntu_dockerwrapper() {
    remote_tmux_run "$pod_host" es933-ubuntu-dockerwrapper-rerun '
        set -e
        if [[ ! -d /tmp/es933-files ]]; then
            echo "/tmp/es933-files is missing on the Ubuntu/SLES VM" >&2
            exit 1
        fi
        for label in ubuntu2204 ubuntu2404; do
            c="es933-${label}"
            docker exec "$c" rm -rf /home/test/scriptx/patch
            docker cp /tmp/es933-files/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
            docker cp /tmp/es933-files/patch "$c:/home/test/scriptx/patch"
            docker exec "$c" bash -lc '"'"'chown -R test:"$(id -gn test)" /home/test/scriptx/build_elasticsearch.sh /home/test/scriptx/patch && chmod +x /home/test/scriptx/build_elasticsearch.sh'"'"'
            cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-${label}-dockerwrapper-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=dockerwrapper at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
            tmux respawn-pane -k -t "es933-full:${label}" "$cmd"
            echo "Docker-wrapper rerun sent to $label"
        done
        sleep 60
    '
}

rerun_sles_networkfix() {
    remote_tmux_run "$pod_host" es933-sles-networkfix-rerun '
        set -e
        if [[ ! -d /tmp/es933-files ]]; then
            echo "/tmp/es933-files is missing on the Ubuntu/SLES VM" >&2
            exit 1
        fi
        label=sles15sp7
        c="es933-${label}"
        docker cp /tmp/es933-files/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
        docker exec "$c" bash -lc '"'"'chown test:"$(id -gn test)" /home/test/scriptx/build_elasticsearch.sh && chmod +x /home/test/scriptx/build_elasticsearch.sh'"'"'
        cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-${label}-networkfix-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=networkfix at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
        tmux respawn-pane -k -t "es933-full:${label}" "$cmd"
        echo "Networkfix rerun sent to $label"
        sleep 60
    '
}

rerun_pod_javafix() {
    remote_tmux_run "$pod_host" es933-pod-javafix-rerun '
        set -e
        if [[ ! -d /tmp/es933-files ]]; then
            echo "/tmp/es933-files is missing on the Ubuntu/SLES VM" >&2
            exit 1
        fi
        for label in ubuntu2204 sles15sp7; do
            c="es933-${label}"
            docker exec "$c" rm -rf /home/test/scriptx/patch
            docker cp /tmp/es933-files/build_elasticsearch.sh "$c:/home/test/scriptx/build_elasticsearch.sh"
            docker cp /tmp/es933-files/patch "$c:/home/test/scriptx/patch"
            docker exec "$c" bash -lc '"'"'chown -R test:"$(id -gn test)" /home/test/scriptx/build_elasticsearch.sh /home/test/scriptx/patch && chmod +x /home/test/scriptx/build_elasticsearch.sh'"'"'
            cmd="docker exec -it -u test ${c} bash -lc '\''cd /home/test/scriptx; run_log=codex-run-${label}-javafix-\$(date +%Y%m%d-%H%M%S).log; echo CODEX_RUN_START label=${label} rerun=javafix at \$(date -Iseconds); bash build_elasticsearch.sh -y 2>&1 | tee \"\$run_log\"; status=\${PIPESTATUS[0]}; echo CODEX_RUN_DONE label=${label} status=\$status log=/home/test/scriptx/\$run_log at \$(date -Iseconds); exec bash'\''"
            tmux respawn-pane -k -t "es933-full:${label}" "$cmd"
            echo "Javafix rerun sent to $label"
        done
        sleep 60
    '
}

compact_host() {
    local host="$1"
    remote_tmux_run "$host" es933-compact-status '
        echo "HOST $(hostname)"
        tmux list-windows -t es933-full -F "#{window_name}" 2>/dev/null | while read -r w; do
            case "$w" in
                monitor) continue ;;
            esac
            text="$(tmux capture-pane -p -J -t "es933-full:$w" -S -220 2>/dev/null || true)"
            echo "[$w]"
            if printf "%s\n" "$text" | grep -qE "CODEX_ML_TEST_DONE .* status=[0-9]+"; then
                printf "%s\n" "$text" | grep -E "CODEX_ML_TEST_DONE .* status=[0-9]+" | tail -1
            elif printf "%s\n" "$text" | grep -qE "CODEX_RUN_DONE .* status=[0-9]+"; then
                printf "%s\n" "$text" | grep -E "CODEX_RUN_DONE .* status=[0-9]+" | tail -1
            elif printf "%s\n" "$text" | grep -qiE "BUILD FAILED|FAILED|Error while|Exiting|Permission denied|No space left|Out of memory|Killed"; then
                printf "%s\n" "$text" | grep -iE "BUILD FAILED|FAILED|Error while|Exiting|Permission denied|No space left|Out of memory|Killed" | tail -5
            else
                printf "%s\n" "$text" | sed "/^[[:space:]]*$/d" | tail -6
            fi
        done
        echo "CONTAINERS"
        if command -v docker >/dev/null 2>&1; then
            docker ps -a | grep es933 || true
        fi
        if command -v podman >/dev/null 2>&1; then
            podman ps -a | grep es933 || true
        fi
        sleep 60
    '
}

sync_live_espatch() {
    remote_tmux_run "$rhel_host" es933-rhel-sync-espatch '
        set -e
        if [[ ! -f /tmp/es933-files/patch/elasticsearch.patch ]]; then
            echo "/tmp/es933-files/patch/elasticsearch.patch is missing on the RHEL VM" >&2
            exit 1
        fi
        for c in es933-rhel810 es933-rhel96 es933-rhel97; do
            docker cp /tmp/es933-files/patch/elasticsearch.patch "$c:/home/test/scriptx/patch/elasticsearch.patch"
            echo "Synced elasticsearch.patch to $c"
        done
        sleep 60
    '
    remote_tmux_run "$pod_host" es933-pod-sync-espatch '
        set -e
        if [[ ! -f /tmp/es933-files/patch/elasticsearch.patch ]]; then
            echo "/tmp/es933-files/patch/elasticsearch.patch is missing on the Ubuntu/SLES VM" >&2
            exit 1
        fi
        for c in es933-ubuntu2204 es933-ubuntu2404 es933-sles15sp7; do
            docker cp /tmp/es933-files/patch/elasticsearch.patch "$c:/home/test/scriptx/patch/elasticsearch.patch"
            echo "Synced elasticsearch.patch to $c"
        done
        sleep 60
    '
}

case "${1:-status}" in
    status)
        status_host "$rhel_host"
        status_host "$pod_host"
        ;;
    compact)
        compact_host "$rhel_host"
        compact_host "$pod_host"
        ;;
    boost)
        inspect_boost_patch
        ;;
    failures)
        failure_logs
        ;;
    rhel-docker)
        rhel_docker_probe
        ;;
    rhel-root-docker)
        rhel_root_docker_probe
        ;;
    rerun-rhel)
        rerun_rhel
        ;;
    rhel-respawn)
        rhel_respawn_build
        ;;
    rerun-rhel96-clean)
        rerun_rhel96_clean
        ;;
    rerun-rhel810-rhel96-clean)
        rerun_rhel810_rhel96_clean
        ;;
    rerun-rhel-latefix)
        rerun_rhel_latefix
        ;;
    rerun-rhel9-runfix)
        rerun_rhel9_runfix
        ;;
    rerun-rhel9-networkfix)
        rerun_rhel9_networkfix
        ;;
    rerun-rhel97-gradlelock)
        rerun_rhel97_gradlelock
        ;;
    rerun-rhel96-gradlelock)
        rerun_rhel96_gradlelock
        ;;
    rerun-rhel810-mlcppdl)
        rerun_rhel810_mlcppdl
        ;;
    inspect-rhel810-compile)
        rhel810_compile_failure
        ;;
    pod-failures)
        pod_failure_logs
        ;;
    rerun-pod-latefix)
        rerun_pod_latefix
        ;;
    rerun-ubuntu-dockerwrapper)
        rerun_ubuntu_dockerwrapper
        ;;
    rerun-sles-networkfix)
        rerun_sles_networkfix
        ;;
    rerun-pod-javafix)
        rerun_pod_javafix
        ;;
    sync-live-espatch)
        sync_live_espatch
        ;;
    inspect)
        inspect_rhel810
        inspect_pod_launch
        ;;
    *)
        echo "usage: $0 [status|compact|inspect]" >&2
        exit 1
        ;;
esac
