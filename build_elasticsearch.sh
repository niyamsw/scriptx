#!/bin/bash
# ©  Copyright IBM Corporation 2026.
# LICENSE: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
#
# Instructions:
# Download build script: wget https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Elasticsearch/9.3.3/build_elasticsearch.sh
# Execute build script: bash build_elasticsearch.sh    (provide -h for help)
#
USER_IN_GROUP_DOCKER=$(id -nGz $USER | tr '\0' '\n' | grep '^docker$' | wc -l)
set -e -o pipefail

PACKAGE_NAME="elasticsearch"
PACKAGE_VERSION="9.3.3"
SOURCE_ROOT="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_PATCH_URL="https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Elasticsearch/${PACKAGE_VERSION}/patch"
if [[ -d "$SCRIPT_DIR/patch" ]]; then
    DEFAULT_PATCH_URL="file://${SCRIPT_DIR}/patch"
fi
PATCH_URL="${PATCH_URL:-$DEFAULT_PATCH_URL}"
ES_REPO_URL="https://github.com/elastic/elasticsearch"
ML_CPP_REPO_URL="${ML_CPP_REPO_URL:-https://github.com/elastic/ml-cpp}"
ML_CPP_REF="${ML_CPP_REF:-v${PACKAGE_VERSION}}"
LOG_FILE="$SOURCE_ROOT/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-$(date +"%F-%T").log"
JAVA_PROVIDED="Temurin21"
NON_ROOT_USER="$(whoami)"
FORCE="false"
BUILD_ENV="$HOME/setenv.sh"
CPU_NUM="$(grep -c ^processor /proc/cpuinfo)"
ES9_OPTS="-x :libs:native:compileMain22Java -x :libs:simdvec:compileMain22Java -x :libs:entitlement:compileMain22Java -x :libs:entitlement:compileMain25Java -x :libs:entitlement:compileMain26Java -x :libs:entitlement:qa:entitlement-test-plugin:compileMain25Java -x :libs:entitlement:qa:entitlement-test-plugin:compileMain26Java"
ML_CPP_REPO="${ML_CPP_REPO:-/tmp/mlcpp-ivy}"
ML_CPP_GRADLE_OPTS=""
ML_CPP_GRADLE_TASKS="${ML_CPP_GRADLE_TASKS:-buildZip buildDependenciesZip buildNoDependenciesZip}"
ML_CPP_FORCE_REBUILD="${ML_CPP_FORCE_REBUILD:-false}"
ML_CPP_SOURCE_DIR="${ML_CPP_SOURCE_DIR:-$SOURCE_ROOT/ml-cpp}"
ML_CPP_JAVA_HOME="${ML_CPP_JAVA_HOME:-/opt/java/jdk17}"
ML_CPP_BOOST_ROOT="${ML_CPP_BOOST_ROOT:-/usr/local/gcc133}"
ML_CPP_BOOST_SOURCE_DIR="${ML_CPP_BOOST_SOURCE_DIR:-$SOURCE_ROOT/boost_1_86_0}"
ML_PYTORCH_ROOT="${ML_PYTORCH_ROOT:-}"
ML_PYTORCH_HOME="${ML_PYTORCH_HOME:-}"
ML_PYTORCH_LIB_DIR="${ML_PYTORCH_LIB_DIR:-}"
ML_PYTORCH_REPO_URL="${ML_PYTORCH_REPO_URL:-https://github.com/pytorch/pytorch}"
ML_PYTORCH_REF="${ML_PYTORCH_REF:-v2.7.1}"
ML_PYTORCH_SOURCE_DIR="${ML_PYTORCH_SOURCE_DIR:-$SOURCE_ROOT/pytorch}"
ML_PYTORCH_BUILD_FROM_SOURCE="${ML_PYTORCH_BUILD_FROM_SOURCE:-true}"
ML_PYTORCH_BUILD_PARALLEL_LEVEL="${ML_PYTORCH_BUILD_PARALLEL_LEVEL:-${ML_CPP_BUILD_PARALLEL_LEVEL:-4}}"
BUILD_TAR_ONLY="false"

trap cleanup 0 1 2 ERR

if [ ! -d "$SOURCE_ROOT/logs/" ]; then
    mkdir -p "$SOURCE_ROOT/logs/"
fi

if [ -f "/etc/os-release" ]; then
    source "/etc/os-release"
fi

DISTRO="$ID-$VERSION_ID"
LOG_FILE="$SOURCE_ROOT/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-${DISTRO}-$(date +"%F-%T").log"

function prepare() {
    if command -v "sudo" >/dev/null; then
        printf -- 'Sudo : Yes\n' >>"$LOG_FILE"
    else
        printf -- 'Sudo : No \n' >>"$LOG_FILE"
        printf -- 'Install sudo from repository using apt, yum or zypper based on your distro. \n'
        exit 1
    fi

    if command -v "docker" >/dev/null; then
        printf -- 'Docker : Yes\n' |& tee -a "${LOG_FILE}"
    else
        printf -- 'Docker : No \n' |& tee -a "${LOG_FILE}"
        printf -- 'Please install Docker based on your distro. \n' |& tee -a "${LOG_FILE}"
        exit 1
    fi

    local have_docker_compose="false"
    if docker compose version >/dev/null 2>&1; then
        have_docker_compose="true"
    fi
    if [[ $have_docker_compose == "true" ]]; then
        printf -- 'Docker Compose : Yes\n' |& tee -a "${LOG_FILE}"
    elif [[ $have_docker_compose == "skip" ]]; then
        printf -- 'Docker Compose : Not Available\n' |& tee -a "${LOG_FILE}"
        printf -- 'This platform does not provide a recent Docker Compose plugin required to run some integration tests. \n' |& tee -a "${LOG_FILE}"
        printf -- 'Tests that require Docker Compose will be skipped. \n' |& tee -a "${LOG_FILE}"
    else
        printf -- 'Docker Compose : Not Installed \n' |& tee -a "${LOG_FILE}"
        printf -- 'The Docker Compose plugin is required to run some integration tests. \n' |& tee -a "${LOG_FILE}"
        printf -- 'Tests that require Docker Compose will be skipped. \n' |& tee -a "${LOG_FILE}"
    fi

    if [[ "$USER_IN_GROUP_DOCKER" == "1" ]]; then
        printf -- "User %s belongs to group docker\n" "$USER" |& tee -a "${LOG_FILE}"
    else
        printf -- "Please ensure User %s belongs to group docker.\n" "$USER" |& tee -a "${LOG_FILE}"
        exit 1
    fi

    if [[ "$FORCE" == "true" ]]; then
        printf -- 'Force attribute provided hence continuing with install without confirmation message\n' |& tee -a "$LOG_FILE"
    else
        printf -- 'As part of the installation, dependencies would be installed/upgraded.\n'
        while true; do
            read -r -p "Do you want to continue (y/n) ? :  " yn
            case $yn in
            [Yy]*)
                break
                ;;
            [Nn]*) exit ;;
            *) echo "Please provide Correct input to proceed." ;;
            esac
        done
    fi

    # zero out
    true > "$BUILD_ENV"
}

function cleanup() {
    rm -rf "${SOURCE_ROOT}/jdk.tar.gz"
    rm -rf "${SOURCE_ROOT}/jdk17.tar.gz"
    rm -rf "${SOURCE_ROOT}/v1.5.5.tar.gz"
    rm -rf "${SOURCE_ROOT}/jansi"
    rm -rf "${SOURCE_ROOT}/jansi-jar"
    rm -rf "${SOURCE_ROOT}/ml-cpp.patch"
    printf -- '\nCleaned up the artifacts.\n' >>"$LOG_FILE"
}

function mlCppRepoPath() {
    if [[ "$ML_CPP_REPO" == file://* ]]; then
        printf -- '%s' "${ML_CPP_REPO#file://}"
    elif [[ "$ML_CPP_REPO" == http://* || "$ML_CPP_REPO" == https://* ]]; then
        printf -- ''
    else
        printf -- '%s' "$ML_CPP_REPO"
    fi
}

function mlCppRepoUrl() {
    if [[ "$ML_CPP_REPO" == file://* || "$ML_CPP_REPO" == http://* || "$ML_CPP_REPO" == https://* ]]; then
        printf -- '%s' "$ML_CPP_REPO"
    else
        printf -- 'file://%s' "$ML_CPP_REPO"
    fi
}

function mlCppArtifactDir() {
    local ml_cpp_repo_path="$1"
    printf -- '%s/maven/org/elasticsearch/ml/ml-cpp/%s-SNAPSHOT' "$ml_cpp_repo_path" "$PACKAGE_VERSION"
}

function ensureMlCppDepsZip() {
    local deps_zip="$1"

    if [[ -f "$deps_zip" ]]; then
        return 0
    fi

    printf -- 'ml-cpp deps zip was not found; creating an empty deps artifact at %s.\n' "$deps_zip" |& tee -a "$LOG_FILE"
    mkdir -p "$(dirname "$deps_zip")"
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "w").close()' "$deps_zip"
}

function findMlCppBoostLibDir() {
    local candidate_dirs=(
        "$ML_CPP_BOOST_ROOT/lib"
        "$ML_CPP_BOOST_SOURCE_DIR/stage/lib"
    )
    local candidate_dir

    for candidate_dir in "${candidate_dirs[@]}"; do
        if [[ -d "$candidate_dir" ]] && find "$candidate_dir" -maxdepth 1 -type f -name 'libboost_program_options*.so.*' -print -quit | grep -q .; then
            printf -- '%s' "$candidate_dir"
            return 0
        fi
    done

    return 1
}

function patchMlCppS390xBoostDepsZip() {
    local deps_zip="$1"
    local deps_zip_abs
    local boost_lib_dir
    local staging_dir

    ensureMlCppDepsZip "$deps_zip"
    deps_zip_abs="$(cd "$(dirname "$deps_zip")" && pwd -P)/$(basename "$deps_zip")"

    if ! boost_lib_dir="$(findMlCppBoostLibDir)"; then
        printf -- 'Unable to find Boost runtime libraries for s390x ml-cpp packaging.\n' |& tee -a "$LOG_FILE"
        printf -- 'Checked %s/lib and %s/stage/lib.\n' "$ML_CPP_BOOST_ROOT" "$ML_CPP_BOOST_SOURCE_DIR" |& tee -a "$LOG_FILE"
        exit 1
    fi

    staging_dir="$(mktemp -d)"
    mkdir -p "$staging_dir/platform/linux-s390x/lib"

    printf -- 'Adding s390x Boost runtime libraries from %s to %s.\n' "$boost_lib_dir" "$deps_zip" |& tee -a "$LOG_FILE"
    find "$boost_lib_dir" \
        -maxdepth 1 \
        -type f \
        -name 'libboost*.so.*' \
        ! -name '*unit_test_framework*' \
        ! -name '*prg_exec_monitor*' \
        -exec cp -av {} "$staging_dir/platform/linux-s390x/lib" \; |& tee -a "$LOG_FILE"

    if ! find "$staging_dir/platform/linux-s390x/lib" -maxdepth 1 -type f -name 'libboost*.so.*' -print -quit | grep -q .; then
        printf -- 'No Boost runtime libraries were staged for s390x ml-cpp packaging.\n' |& tee -a "$LOG_FILE"
        rm -rf "$staging_dir"
        exit 1
    fi

    (
          cd "$staging_dir"
          set +e
          find platform/linux-s390x/lib -maxdepth 1 -type f -name 'libboost*.so.*' -print -exec touch -t 2401010000 {} \; \
              | sort \
              | zip -X -u "$deps_zip_abs" -@
          zip_status=$?
          set -e
          if [[ "$zip_status" -eq 12 ]]; then
              printf -- 's390x Boost runtime libraries are already present in %s.\n' "$deps_zip_abs"
          elif [[ "$zip_status" -ne 0 ]]; then
              exit "$zip_status"
          fi
      ) |& tee -a "$LOG_FILE"

    rm -rf "$staging_dir"
}

function hasMlCppIvyArtifacts() {
    local ml_cpp_repo_path="$1"
    local ml_cpp_artifact_dir
    local ml_cpp_deps_zip
    local ml_cpp_nodeps_zip

    [[ -n "$ml_cpp_repo_path" ]] || return 1
    ml_cpp_artifact_dir="$(mlCppArtifactDir "$ml_cpp_repo_path")"
    ml_cpp_deps_zip="$ml_cpp_artifact_dir/ml-cpp-${PACKAGE_VERSION}-SNAPSHOT-deps.zip"
    ml_cpp_nodeps_zip="$ml_cpp_artifact_dir/ml-cpp-${PACKAGE_VERSION}-SNAPSHOT-nodeps.zip"

    if [[ -f "$ml_cpp_nodeps_zip" ]]; then
        ensureMlCppDepsZip "$ml_cpp_deps_zip"
        if [[ -f "$ml_cpp_deps_zip" ]]; then
            return 0
        fi
    fi

    return 1
}

function getJavaUrl() {
    local jruntime=$1
    local jdist=$2
    case "${jruntime}" in
    "Temurin21")
        echo "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.9%2B10/OpenJDK21U-${jdist}_s390x_linux_hotspot_21.0.9_10.tar.gz"
        ;;
    "Temurin17")
        echo "https://api.adoptium.net/v3/binary/latest/17/ga/linux/s390x/${jdist}/hotspot/normal/eclipse"
        ;;
    esac
}

function installJava() {
    printf -- "Download and install Java \n"
    cd "$SOURCE_ROOT"
    if [ -d "/opt/java" ]; then sudo rm -Rf /opt/java; fi
    if [[ $JAVA_PROVIDED =~ ^Temurin ]]; then
        sudo mkdir -p /opt/java/jdk
        curl -SL -o jdk.tar.gz "$(getJavaUrl $JAVA_PROVIDED jdk)"
        sudo tar -zxf jdk.tar.gz -C /opt/java/jdk --strip-components 1
        sudo update-alternatives --install "/usr/bin/java" "java" "/opt/java/jdk/bin/java" 40
        sudo update-alternatives --install "/usr/bin/javac" "javac" "/opt/java/jdk/bin/javac" 40
        sudo update-alternatives --set java "/opt/java/jdk/bin/java"
        sudo update-alternatives --set javac "/opt/java/jdk/bin/javac"
        export ES_JAVA_HOME=/opt/java/jdk
    else
        printf "%s is not supported, Please use valid java {Temurin21} only\n" "$JAVA_PROVIDED"
        exit 1
    fi
}

function installMlCppJava() {
    if [[ -x "$ML_CPP_JAVA_HOME/bin/java" ]]; then
        return
    fi

    printf -- "Download and install Java 17 for ml-cpp build \n"
    cd "$SOURCE_ROOT"
    sudo mkdir -p "$ML_CPP_JAVA_HOME"
    curl -SL -o jdk17.tar.gz "$(getJavaUrl Temurin17 jdk)"
    sudo tar -zxf jdk17.tar.gz -C "$ML_CPP_JAVA_HOME" --strip-components 1
}

function installMlCppBoost() {
    if find "$ML_CPP_BOOST_ROOT" -path '*/BoostConfig.cmake' -print -quit 2>/dev/null | grep -q .; then
        printf -- 'Using existing Boost 1.86 installation at %s\n' "$ML_CPP_BOOST_ROOT" |& tee -a "$LOG_FILE"
        return
    fi

    printf -- 'Building Boost 1.86 for ml-cpp.\n' |& tee -a "$LOG_FILE"
    cd "$SOURCE_ROOT"
    if [[ ! -d "$ML_CPP_BOOST_SOURCE_DIR" ]]; then
        curl -SL -o boost_1_86_0.tar.bz2 https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.bz2
        tar -xjf boost_1_86_0.tar.bz2
    fi

    cd "$ML_CPP_BOOST_SOURCE_DIR"
    ./bootstrap.sh --without-libraries=context,coroutine,graph_parallel,mpi,python --without-icu |& tee -a "$LOG_FILE"
    sed -i -e 's/{13ul/{3ul, 13ul/' boost/unordered/detail/prime_fmod.hpp
    ./b2 -j"${ML_CPP_BUILD_PARALLEL_LEVEL:-4}" \
        --with-iostreams \
        --with-filesystem \
        --with-program_options \
        --with-regex \
        --with-date_time \
        --with-log \
        --with-thread \
        --with-test \
        --layout=versioned --disable-icu pch=off optimization=speed inlining=full \
        define=BOOST_MATH_NO_LONG_DOUBLE_MATH_FUNCTIONS \
        define=BOOST_LOG_WITHOUT_DEBUG_OUTPUT \
        define=BOOST_LOG_WITHOUT_EVENT_LOG \
        define=BOOST_LOG_WITHOUT_SYSLOG \
        define=BOOST_LOG_WITHOUT_IPC \
        define=_FORTIFY_SOURCE=2 \
        cxxflags='-std=gnu++17 -fstack-protector' \
        cflags='-D__STDC_FORMAT_MACROS' \
        linkflags='-std=gnu++17 -Wl,-z,relro -Wl,-z,now' |& tee -a "$LOG_FILE"
    sudo ./b2 install --prefix="$ML_CPP_BOOST_ROOT" \
        --with-iostreams \
        --with-filesystem \
        --with-program_options \
        --with-regex \
        --with-date_time \
        --with-log \
        --with-thread \
        --with-test \
        --layout=versioned --disable-icu pch=off optimization=speed inlining=full \
        define=BOOST_MATH_NO_LONG_DOUBLE_MATH_FUNCTIONS \
        define=BOOST_LOG_WITHOUT_DEBUG_OUTPUT \
        define=BOOST_LOG_WITHOUT_EVENT_LOG \
        define=BOOST_LOG_WITHOUT_SYSLOG \
        define=BOOST_LOG_WITHOUT_IPC \
        define=_FORTIFY_SOURCE=2 \
        cxxflags='-std=gnu++17 -fstack-protector' \
        cflags='-D__STDC_FORMAT_MACROS' \
        linkflags='-std=gnu++17 -Wl,-z,relro -Wl,-z,now' |& tee -a "$LOG_FILE"
}

function installMlCppSystemPrefixLinks() {
    sudo mkdir -p "$ML_CPP_BOOST_ROOT/include" "$ML_CPP_BOOST_ROOT/lib"

    if [[ -d /usr/include/libxml2 && ! -e "$ML_CPP_BOOST_ROOT/include/libxml2" ]]; then
        sudo ln -s /usr/include/libxml2 "$ML_CPP_BOOST_ROOT/include/libxml2"
    fi
    if [[ -e /usr/lib64/libxml2.so ]]; then
        sudo ln -sfn /usr/lib64/libxml2.so "$ML_CPP_BOOST_ROOT/lib/libxml2.so"
    elif [[ -e /usr/lib/libxml2.so ]]; then
        sudo ln -sfn /usr/lib/libxml2.so "$ML_CPP_BOOST_ROOT/lib/libxml2.so"
    fi
}

function installMlCppBinutilsAliases() {
    if [[ "$(uname -m)" != "s390x" ]]; then
        return
    fi

    local objcopy_path
    local strip_path
    objcopy_path="$(command -v objcopy || true)"
    strip_path="$(command -v strip || true)"

    if [[ -z "$objcopy_path" || -z "$strip_path" ]]; then
        printf -- 'binutils objcopy and strip are required for the s390x ml-cpp strip task.\n' |& tee -a "$LOG_FILE"
        exit 1
    fi

    sudo ln -sfn "$objcopy_path" /usr/local/bin/s390x-linux-gnu-objcopy
    sudo ln -sfn "$strip_path" /usr/local/bin/s390x-linux-gnu-strip
}

function verifyMlCppRepo() {
    local ml_cpp_repo_path
    local ml_cpp_artifact_dir
    local missing_artifacts=()

    ml_cpp_repo_path="$(mlCppRepoPath)"

    if [[ -n "$ml_cpp_repo_path" && ! -d "$ml_cpp_repo_path" ]]; then
        printf -- 'Required ml-cpp Ivy repository not found at %s.\n' "$ml_cpp_repo_path" |& tee -a "$LOG_FILE"
        printf -- 'The ml-cpp build did not create the expected Ivy repository.\n' |& tee -a "$LOG_FILE"
        exit 1
    fi

    if [[ -n "$ml_cpp_repo_path" ]]; then
        ml_cpp_artifact_dir="$(mlCppArtifactDir "$ml_cpp_repo_path")"
        if hasMlCppIvyArtifacts "$ml_cpp_repo_path"; then
            return 0
        fi
        for artifact in \
            "$ml_cpp_artifact_dir/ml-cpp-${PACKAGE_VERSION}-SNAPSHOT-deps.zip" \
            "$ml_cpp_artifact_dir/ml-cpp-${PACKAGE_VERSION}-SNAPSHOT-nodeps.zip"; do
            if [[ ! -f "$artifact" ]]; then
                missing_artifacts+=("$artifact")
            fi
        done

        if (( ${#missing_artifacts[@]} > 0 )); then
            printf -- 'Required s390x ml-cpp artifacts are missing:\n' |& tee -a "$LOG_FILE"
            printf -- '  %s\n' "${missing_artifacts[@]}" |& tee -a "$LOG_FILE"
            printf -- 'The ml-cpp build did not create the expected deps/nodeps artifacts.\n' |& tee -a "$LOG_FILE"
            exit 1
        fi
    fi
}

function configureMlCppRepo() {
    local ml_cpp_repo_url

    verifyMlCppRepo
    ml_cpp_repo_url="$(mlCppRepoUrl)"
    ML_CPP_GRADLE_OPTS="-Dbuild.ml_cpp.repo=$ml_cpp_repo_url"
    export ML_CPP_REPO ML_CPP_GRADLE_OPTS
    grep -q "ML_CPP_REPO" "$BUILD_ENV" || printf -- "export ML_CPP_REPO=%q\n" "$ML_CPP_REPO" >> "$BUILD_ENV"
    grep -q "ML_CPP_GRADLE_OPTS" "$BUILD_ENV" || printf -- "export ML_CPP_GRADLE_OPTS=%q\n" "$ML_CPP_GRADLE_OPTS" >> "$BUILD_ENV"
    printf -- "Using ml-cpp Ivy repository: %s\n" "$ml_cpp_repo_url" |& tee -a "$LOG_FILE"
}

function resolveMlCppPytorchRoot() {
    local root="$1"
    local include_dir="$root/include"

    if [[ -d "$root/include/pytorch/torch" || -d "$root/include/pytorch/c10" ]]; then
        include_dir="$root/include/pytorch"
    fi

    if [[ -d "$include_dir" && -f "$root/lib/libtorch_cpu.so" && -f "$root/lib/libc10.so" ]]; then
        ML_PYTORCH_HOME="$include_dir"
        ML_PYTORCH_LIB_DIR="$root/lib"
        return 0
    fi
    return 1
}

function resolveMlCppPytorchSourceBuild() {
    local root="$1"
    local lib_dir="$root/build/lib"

    if [[ -d "$root/torch/csrc/api/include" && -f "$lib_dir/libtorch_cpu.so" && -f "$lib_dir/libc10.so" ]]; then
        ML_PYTORCH_HOME="$root"
        ML_PYTORCH_LIB_DIR="$lib_dir"
        return 0
    fi
    return 1
}

function validateMlCppPytorch() {
    if [[ -z "$ML_PYTORCH_HOME" || -z "$ML_PYTORCH_LIB_DIR" ]]; then
        printf -- 'ML_PYTORCH_HOME and ML_PYTORCH_LIB_DIR must both be set for the s390x ml-cpp build.\n' |& tee -a "$LOG_FILE"
        if [[ -n "${ML_PYTORCH_SEARCH_PATHS:-}" ]]; then
            printf -- 'Searched for a GCC13 PyTorch root in:\n%s\n' "$ML_PYTORCH_SEARCH_PATHS" |& tee -a "$LOG_FILE"
        fi
        printf -- 'Provide ML_PYTORCH_ROOT, or mount/copy the GCC13 PyTorch bundle to one of the searched locations.\n' |& tee -a "$LOG_FILE"
        exit 1
    fi
    if [[ ! -d "$ML_PYTORCH_HOME" ]]; then
        printf -- 'ML_PYTORCH_HOME does not exist: %s\n' "$ML_PYTORCH_HOME" |& tee -a "$LOG_FILE"
        exit 1
    fi
    if [[ ! -f "$ML_PYTORCH_LIB_DIR/libtorch_cpu.so" || ! -f "$ML_PYTORCH_LIB_DIR/libc10.so" ]]; then
        printf -- 'ML_PYTORCH_LIB_DIR must contain libtorch_cpu.so and libc10.so: %s\n' "$ML_PYTORCH_LIB_DIR" |& tee -a "$LOG_FILE"
        exit 1
    fi

    if command -v readelf >/dev/null 2>&1; then
        local torch_comment
        torch_comment="$(readelf -p .comment "$ML_PYTORCH_LIB_DIR/libtorch_cpu.so" 2>/dev/null || true)"
        if [[ "$torch_comment" == *"GCC:"* && ! "$torch_comment" =~ GCC:.*13\. ]]; then
            printf -- 'libtorch_cpu.so was not built with GCC 13; this is known to break ml-cpp on s390x.\n' |& tee -a "$LOG_FILE"
            printf -- 'Provide a GCC13-built PyTorch via ML_PYTORCH_ROOT or ML_PYTORCH_HOME/ML_PYTORCH_LIB_DIR.\n' |& tee -a "$LOG_FILE"
            exit 1
        fi
    fi
}

function buildMlCppPytorch() {
    if [[ "$ML_PYTORCH_BUILD_FROM_SOURCE" != "true" ]]; then
        return
    fi

    if resolveMlCppPytorchSourceBuild "$ML_PYTORCH_SOURCE_DIR"; then
        printf -- 'Using existing PyTorch source build: source=%s lib=%s\n' "$ML_PYTORCH_HOME" "$ML_PYTORCH_LIB_DIR" |& tee -a "$LOG_FILE"
        return
    fi

    printf -- 'Building PyTorch %s from source for s390x ml-cpp.\n' "$ML_PYTORCH_REF" |& tee -a "$LOG_FILE"
    if [[ -d "$ML_PYTORCH_SOURCE_DIR/.git" ]]; then
        printf -- 'Using existing PyTorch source at %s\n' "$ML_PYTORCH_SOURCE_DIR" |& tee -a "$LOG_FILE"
    else
        rm -rf "$ML_PYTORCH_SOURCE_DIR"
        git clone --recursive --depth 1 --branch "$ML_PYTORCH_REF" "$ML_PYTORCH_REPO_URL" "$ML_PYTORCH_SOURCE_DIR"
    fi

    cd "$ML_PYTORCH_SOURCE_DIR"
    git submodule sync --recursive
    git submodule update --init --recursive --jobs "${ML_PYTORCH_BUILD_PARALLEL_LEVEL}"

    if ! python3 -m pip --version >/dev/null 2>&1; then
        local python_version get_pip_url
        python_version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
        get_pip_url="https://bootstrap.pypa.io/get-pip.py"
        if [[ "$python_version" == "3.9" ]]; then
            get_pip_url="https://bootstrap.pypa.io/pip/3.9/get-pip.py"
        elif [[ "$python_version" == "3.8" ]]; then
            get_pip_url="https://bootstrap.pypa.io/pip/3.8/get-pip.py"
        fi
        curl -SL -o get-pip.py "$get_pip_url"
        python3 get-pip.py --user
    fi

    python3 -m pip install --user --upgrade setuptools wheel
    python3 -m pip install --user -r requirements.txt
    python3 -m pip install --user pyyaml typing_extensions numpy ninja cmake cffi sympy networkx jinja2 fsspec filelock

    if [[ -f /opt/rh/gcc-toolset-13/enable ]]; then
        # shellcheck disable=SC1091
        source /opt/rh/gcc-toolset-13/enable
    fi

    export PATH="$HOME/.local/bin:$PATH"
    export CC="${CC:-gcc}"
    export CXX="${CXX:-g++}"
    export MAX_JOBS="$ML_PYTORCH_BUILD_PARALLEL_LEVEL"
    export BUILD_SHARED_LIBS=ON
    export BUILD_TEST=0
    export BUILD_PYTHON=0
    export BUILD_CAFFE2_OPS=0
    export USE_CUDA=0
    export USE_ROCM=0
    export USE_DISTRIBUTED=0
    export USE_MPI=0
    export USE_NCCL=0
    export USE_GLOO=0
    export USE_MKLDNN=0
    export USE_FBGEMM=0
    export USE_NNPACK=0
    export USE_QNNPACK=0
    export USE_XNNPACK=0
    export USE_KINETO=0
    export USE_MPS=0

    python3 tools/build_libtorch.py |& tee -a "$LOG_FILE"

    if ! resolveMlCppPytorchSourceBuild "$ML_PYTORCH_SOURCE_DIR"; then
        printf -- 'PyTorch build did not create required libtorch artifacts under %s/build/lib.\n' "$ML_PYTORCH_SOURCE_DIR" |& tee -a "$LOG_FILE"
        exit 1
    fi
}

function configureMlCppPytorch() {
    local candidate
    local candidates

    if [[ -n "$ML_PYTORCH_ROOT" ]]; then
        if ! resolveMlCppPytorchRoot "$ML_PYTORCH_ROOT"; then
            printf -- 'ML_PYTORCH_ROOT must contain include/, lib/libtorch_cpu.so and lib/libc10.so: %s\n' "$ML_PYTORCH_ROOT" |& tee -a "$LOG_FILE"
            exit 1
        fi
    elif [[ -z "$ML_PYTORCH_HOME" && -z "$ML_PYTORCH_LIB_DIR" ]]; then
        candidates=(
            "$ML_CPP_SOURCE_DIR/deps/pytorch-gcc13"
            "$SOURCE_ROOT/deps/pytorch-gcc13"
            "$SOURCE_ROOT/pytorch-gcc13"
            "/usr/local/gcc133"
            "/opt/pytorch-gcc13"
            "/usr/local/pytorch-gcc13"
        )
        ML_PYTORCH_SEARCH_PATHS="$(printf -- '  %s\n' "${candidates[@]}")"
        for candidate in "${candidates[@]}"; do
            if resolveMlCppPytorchRoot "$candidate"; then
                break
            fi
        done
    fi

    if [[ -z "$ML_PYTORCH_HOME" || -z "$ML_PYTORCH_LIB_DIR" ]]; then
        buildMlCppPytorch
    fi

    validateMlCppPytorch
    export ML_PYTORCH_HOME ML_PYTORCH_LIB_DIR
    grep -q "ML_PYTORCH_HOME" "$BUILD_ENV" || printf -- "export ML_PYTORCH_HOME=%q\n" "$ML_PYTORCH_HOME" >> "$BUILD_ENV"
    grep -q "ML_PYTORCH_LIB_DIR" "$BUILD_ENV" || printf -- "export ML_PYTORCH_LIB_DIR=%q\n" "$ML_PYTORCH_LIB_DIR" >> "$BUILD_ENV"
    printf -- "Using GCC13 PyTorch for ml-cpp: include=%s lib=%s\n" "$ML_PYTORCH_HOME" "$ML_PYTORCH_LIB_DIR" |& tee -a "$LOG_FILE"
}

function buildMlCpp() {
    local ml_cpp_repo_path
    local ml_cpp_artifact_dir
    local ml_cpp_dist_dir
    local ml_cpp_deps_zip
    local ml_cpp_nodeps_zip
    local ml_cpp_cmake_flags="${CMAKE_FLAGS:-}"

    ml_cpp_repo_path="$(mlCppRepoPath)"
    if [[ -z "$ml_cpp_repo_path" ]]; then
        printf -- 'Using remote ml-cpp Ivy repository: %s\n' "$(mlCppRepoUrl)" |& tee -a "$LOG_FILE"
        configureMlCppRepo
        return
    fi

    ml_cpp_artifact_dir="$(mlCppArtifactDir "$ml_cpp_repo_path")"
    if [[ "$ML_CPP_FORCE_REBUILD" != "true" ]] && hasMlCppIvyArtifacts "$ml_cpp_repo_path"; then
        printf -- 'Using existing s390x ml-cpp Ivy artifacts from %s\n' "$ml_cpp_artifact_dir" |& tee -a "$LOG_FILE"
        patchMlCppS390xBoostDepsZip "$ml_cpp_artifact_dir/ml-cpp-${PACKAGE_VERSION}-SNAPSHOT-deps.zip"
        configureMlCppRepo
        return
    fi

    if [[ -d "$ML_CPP_SOURCE_DIR/.git" ]]; then
        printf -- 'Using existing ml-cpp source at %s\n' "$ML_CPP_SOURCE_DIR" |& tee -a "$LOG_FILE"
    else
        printf -- 'Downloading ml-cpp. Please wait.\n' |& tee -a "$LOG_FILE"
        rm -rf "$ML_CPP_SOURCE_DIR"
        git clone --depth 1 -b "$ML_CPP_REF" "$ML_CPP_REPO_URL" "$ML_CPP_SOURCE_DIR"
    fi

    installMlCppJava
    installMlCppBoost
    installMlCppSystemPrefixLinks
    installMlCppBinutilsAliases
    configureMlCppPytorch

    cd "$ML_CPP_SOURCE_DIR"
    curl -sSL "${PATCH_URL}/ml-cpp.patch" -o "$SOURCE_ROOT/ml-cpp.patch"
    if git apply --check "$SOURCE_ROOT/ml-cpp.patch" >/dev/null 2>&1; then
        git apply "$SOURCE_ROOT/ml-cpp.patch"
    elif git apply --reverse --check "$SOURCE_ROOT/ml-cpp.patch" >/dev/null 2>&1; then
        printf -- 'ml-cpp s390x patch is already applied.\n' |& tee -a "$LOG_FILE"
    else
        printf -- 'Unable to apply ml-cpp s390x patch.\n' |& tee -a "$LOG_FILE"
        exit 1
    fi

    ml_cpp_dist_dir="$ML_CPP_SOURCE_DIR/build/distributions"
    ml_cpp_deps_zip="$ml_cpp_dist_dir/ml-cpp-${PACKAGE_VERSION}-SNAPSHOT-deps.zip"
    ml_cpp_nodeps_zip="$ml_cpp_dist_dir/ml-cpp-${PACKAGE_VERSION}-SNAPSHOT-nodeps.zip"
    if [[ -f "$ml_cpp_nodeps_zip" ]]; then
        if [[ ! -f "$ml_cpp_deps_zip" ]]; then
            ensureMlCppDepsZip "$ml_cpp_deps_zip"
        fi
        patchMlCppS390xBoostDepsZip "$ml_cpp_deps_zip"
        mkdir -p "$ml_cpp_artifact_dir"
        cp "$ml_cpp_deps_zip" "$ml_cpp_artifact_dir/"
        cp "$ml_cpp_nodeps_zip" "$ml_cpp_artifact_dir/"
        printf -- 'Using existing ml-cpp artifacts from %s\n' "$ml_cpp_dist_dir" |& tee -a "$LOG_FILE"
        configureMlCppRepo
        return
    fi

    printf -- 'Building s390x ml-cpp artifacts.\n' |& tee -a "$LOG_FILE"
    export GRADLE_USER_HOME=$SOURCE_ROOT/.gradle
    if [[ -x /opt/rh/gcc-toolset-13/root/usr/bin/gcc && -x /opt/rh/gcc-toolset-13/root/usr/bin/g++ ]]; then
        ml_cpp_cmake_flags="${ml_cpp_cmake_flags} -DCMAKE_C_COMPILER=/opt/rh/gcc-toolset-13/root/usr/bin/gcc -DCMAKE_CXX_COMPILER=/opt/rh/gcc-toolset-13/root/usr/bin/g++"
    fi
    CPP_CROSS_COMPILE=s390x CMAKE_BUILD_PARALLEL_LEVEL="${ML_CPP_BUILD_PARALLEL_LEVEL:-4}" JAVA_HOME="$ML_CPP_JAVA_HOME" PATH="$ML_CPP_JAVA_HOME/bin:$PATH" CMAKE_FLAGS="$ml_cpp_cmake_flags" BOOST_ROOT="$ML_CPP_BOOST_ROOT" ML_PYTORCH_HOME="$ML_PYTORCH_HOME" ML_PYTORCH_LIB_DIR="$ML_PYTORCH_LIB_DIR" ./gradlew ${ML_CPP_GRADLE_TASKS} -Dbuild.snapshot=true |& tee -a "$LOG_FILE"

    if [[ ! -f "$ml_cpp_deps_zip" ]]; then
        ensureMlCppDepsZip "$ml_cpp_deps_zip"
    fi
    patchMlCppS390xBoostDepsZip "$ml_cpp_deps_zip"
    mkdir -p "$ml_cpp_artifact_dir"
    cp "$ml_cpp_deps_zip" "$ml_cpp_artifact_dir/"
    cp "$ml_cpp_nodeps_zip" "$ml_cpp_artifact_dir/"

    configureMlCppRepo
}

function createS390xGradleFile() {
    local dist_subdir="$1"
    local dist_dir="$SOURCE_ROOT/elasticsearch/distribution/${dist_subdir}"
    mkdir -p "$dist_dir"
    echo '
        // This file is intentionally blank. All configuration of the
        // export is done in the parent project.
        ' > "${dist_dir}/build.gradle"
}

function buildS390xUbiMicrodnfImage() {
    local docker_image_tag="$1"
    local install_command="$2"
    local base_image="redhat/ubi9-minimal:latest"
    local container="es-ubi-s390x-dind-$$"

    if [[ "$(uname -m)" != "s390x" ]]; then
        return 1
    fi

    if docker image inspect "$docker_image_tag" >/dev/null 2>&1; then
        printf -- 'Using existing %s image.\n' "$docker_image_tag" |& tee -a "$LOG_FILE"
        return 0
    fi

    docker image inspect "$base_image" >/dev/null 2>&1 || docker pull "$base_image"
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run \
        --privileged \
        --network=host \
        --name "$container" \
        "$base_image" \
        sh -lc "$install_command"

    docker commit "$container" "$docker_image_tag"
    docker rm -f "$container" >/dev/null 2>&1 || true
}

function prepareS390xDockerBuildAssets() {
    local docker_context_dir="$1"
    local assets_dir="$docker_context_dir/s390x-build-assets"

    mkdir -p "$assets_dir"
    [[ -f "$assets_dir/tini-s390x" ]] || curl -f --retry 10 -S -L -o "$assets_dir/tini-s390x" "https://github.com/krallin/tini/releases/download/v0.19.0/tini-s390x"
    [[ -f "$assets_dir/jansi-2.4.0.tar.gz" ]] || curl -f --retry 10 -S -L -o "$assets_dir/jansi-2.4.0.tar.gz" "https://github.com/fusesource/jansi/archive/refs/tags/jansi-2.4.0.tar.gz"
    [[ -f "$assets_dir/jansi-2.4.0.jar" ]] || curl -f --retry 10 -S -L -o "$assets_dir/jansi-2.4.0.jar" "https://repo1.maven.org/maven2/org/fusesource/jansi/jansi/2.4.0/jansi-2.4.0.jar"
    [[ -f "$assets_dir/v1.5.5.tar.gz" ]] || curl -f --retry 10 -S -L -o "$assets_dir/v1.5.5.tar.gz" "https://github.com/facebook/zstd/archive/refs/tags/v1.5.5.tar.gz"
}

function patchS390xDockerfileForLegacyBuilder() {
    local docker_context_dir="$SOURCE_ROOT/elasticsearch/distribution/docker/build/docker-context/elasticsearch-${PACKAGE_VERSION}-SNAPSHOT-docker-build-context-s390x"
    local dockerfile="$docker_context_dir/Dockerfile"

    if [[ ! -f "$dockerfile" ]]; then
        printf -- 'Dockerfile not found at %s\n' "$dockerfile"
        exit 1
    fi

    if [[ "$(uname -m)" == "s390x" ]]; then
        prepareS390xDockerBuildAssets "$docker_context_dir"
        buildS390xUbiMicrodnfImage "elasticsearch-ubi9-builder:s390x-dind" "microdnf install -y findutils tar gzip make gcc && microdnf clean all"
        buildS390xUbiMicrodnfImage "elasticsearch-ubi9-runtime-user:s390x-dind" "microdnf install --setopt=tsflags=nodocs -y nc shadow-utils zip unzip findutils procps-ng && microdnf clean all && printf 'elasticsearch:x:1000:\n' >> /etc/group && printf 'elasticsearch:x:1000:1000::/usr/share/elasticsearch:/sbin/nologin\n' >> /etc/passwd && sed -i 's/^root:x:0:$/root:x:0:elasticsearch/' /etc/group"
        sed -i \
            -e 's|^FROM redhat/ubi9-minimal:latest AS builder|FROM elasticsearch-ubi9-builder:s390x-dind AS builder|' \
            -e '/^FROM elasticsearch-ubi9-builder:s390x-dind AS builder/a COPY s390x-build-assets /tmp/s390x-build-assets' \
            -e '/^RUN microdnf install -y findutils tar gzip make gcc$/d' \
            -e '0,/^FROM redhat\/ubi9-minimal:latest$/s|^FROM redhat/ubi9-minimal:latest$|FROM elasticsearch-ubi9-runtime-user:s390x-dind|' \
            -e '/^RUN microdnf install --setopt=tsflags=nodocs -y \\/,/^    microdnf clean all$/d' \
            -e '/^RUN groupadd -g 1000 elasticsearch && \\/,/^    chown -R 0:0 \/usr\/share\/elasticsearch$/d' \
            -e 's|curl -f --retry 10 -S -L -o /tmp/tini https://github.com/krallin/tini/releases/download/v0.19.0/${tini_bin};|cp /tmp/s390x-build-assets/${tini_bin} /tmp/tini;|' \
            -e 's|curl --retry 10 -S -L -O https://github.com/fusesource/jansi/archive/refs/tags/jansi-2.4.0.tar.gz|cp /tmp/s390x-build-assets/jansi-2.4.0.tar.gz .|' \
            -e 's|curl --retry 10 -S -L -O https://repo1.maven.org/maven2/org/fusesource/jansi/jansi/2.4.0/jansi-2.4.0.jar|cp /tmp/s390x-build-assets/jansi-2.4.0.jar .|' \
            -e 's|curl --retry 10 -S -L -O https://github.com/facebook/zstd/archive/refs/tags/v1.5.5.tar.gz|cp /tmp/s390x-build-assets/v1.5.5.tar.gz .|' \
            "$dockerfile"
    fi

    sed -i \
        -e 's|^COPY --chmod=664 config/elasticsearch.yml config/log4j2.properties config/|COPY config/elasticsearch.yml config/log4j2.properties config/\nRUN chmod 0664 config/elasticsearch.yml config/log4j2.properties|' \
        -e 's|^COPY --chmod=0555 bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh|COPY bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh\nRUN chmod 0555 /usr/local/bin/docker-entrypoint.sh|' \
        "$dockerfile"
}

function buildS390xDockerDistribution() {
    local docker_context_dir="$SOURCE_ROOT/elasticsearch/distribution/docker/build/docker-context/elasticsearch-${PACKAGE_VERSION}-SNAPSHOT-docker-build-context-s390x"
    local docker_export_dir="$SOURCE_ROOT/elasticsearch/distribution/docker/docker-s390x-export/build/distributions"
    local docker_image_tag="docker.elastic.co/elasticsearch/elasticsearch:${PACKAGE_VERSION}-SNAPSHOT-s390x"
    local docker_image_tar="$docker_export_dir/elasticsearch-${PACKAGE_VERSION}-SNAPSHOT-docker-image-s390x.tar.gz"

    cd "$SOURCE_ROOT/elasticsearch"
    ./gradlew :distribution:archives:buildLinuxS390x :distribution:docker:transforms390xDockerContext $ES9_OPTS $ML_CPP_GRADLE_OPTS
    patchS390xDockerfileForLegacyBuilder
    DOCKER_BUILDKIT=0 docker build -f "$docker_context_dir/Dockerfile" -t "$docker_image_tag" "$docker_context_dir"
    mkdir -p "$docker_export_dir"
    DOCKER_BUILDKIT=0 docker save "$docker_image_tag" | gzip -c > "$docker_image_tar"
}

function buildS390xSmbFixtureImage() {
    local docker_context_dir="$1"
    local docker_image_tag="$2"
    local pre_image="${docker_image_tag}-pre-s390x-dind"
    local apt_image="${docker_image_tag}-apt-s390x-dind"
    local base_image="public.ecr.aws/docker/library/ubuntu:24.04"
    local mirror_image="mirror.gcr.io/library/ubuntu:24.04"
    local container="es-smb-s390x-dind-$$"
    local tmpdir

    if [[ "$(uname -m)" != "s390x" ]]; then
        return 1
    fi

    docker image inspect "$base_image" >/dev/null 2>&1 \
        || docker pull "$base_image" \
        || { docker pull "$mirror_image" && docker tag "$mirror_image" "$base_image"; }

    tmpdir="$(mktemp -d)"

    cat > "$tmpdir/Dockerfile.pre" <<'EOF'
FROM public.ecr.aws/docker/library/ubuntu:24.04

ENV TZ="Etc/UTC"
ENV DEBIAN_FRONTEND=noninteractive
EOF

    DOCKER_BUILDKIT=0 docker build -f "$tmpdir/Dockerfile.pre" -t "$pre_image" "$docker_context_dir"

    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run \
        --name "$container" \
        --privileged \
        --network=host \
        "$pre_image" \
        /bin/sh -ec 'DEBIAN_FRONTEND=noninteractive apt-get update -qqy && apt-get install -qqy tzdata winbind samba ldap-utils'
    docker commit "$container" "$apt_image" >/dev/null
    docker rm -f "$container" >/dev/null

    cat > "$tmpdir/Dockerfile.final" <<EOF
FROM $apt_image

COPY smb/provision/installsmb.sh /fixture/provision/installsmb.sh
COPY smb/certs/ca.key /fixture/certs/ca.key
COPY smb/certs/ca.pem /fixture/certs/ca.pem
COPY smb/certs/cert.pem /fixture/certs/cert.pem
COPY smb/certs/key.pem /fixture/certs/key.pem

RUN chmod +x /fixture/provision/installsmb.sh

CMD ["/bin/sh", "-c", "/fixture/provision/installsmb.sh && service samba-ad-dc restart && echo Samba started && sleep infinity"]
EOF

    DOCKER_BUILDKIT=0 docker build -f "$tmpdir/Dockerfile.final" -t "$docker_image_tag" "$docker_context_dir"
    rm -rf "$tmpdir"
}

function buildS390xMinioImage() {
    local docker_context_dir="$1"
    local docker_image_tag="$2"
    local release="$3"
    local mc_release="$4"
    local build_base_image="${docker_image_tag}-buildbase-s390x-dind"
    local build_image="${docker_image_tag}-build-s390x-dind"
    local base_image="public.ecr.aws/docker/library/golang:1.24-alpine"
    local mirror_image="mirror.gcr.io/library/golang:1.24-alpine"
    local container="minio-build-s390x-dind-$$"
    local tmpdir

    if [[ "$(uname -m)" != "s390x" ]]; then
        return 1
    fi

    docker image inspect "$base_image" >/dev/null 2>&1 \
        || docker pull "$base_image" \
        || { docker pull "$mirror_image" && docker tag "$mirror_image" "$base_image"; }

    tmpdir="$(mktemp -d)"

    cat > "$tmpdir/Dockerfile.buildbase" <<'EOF'
FROM public.ecr.aws/docker/library/golang:1.24-alpine AS build

ARG TARGETARCH
ARG RELEASE
ARG MC_RELEASE
ENV GOPATH=/go
ENV CGO_ENABLED=0

WORKDIR /build

RUN apk add -U --no-cache ca-certificates && \
    apk add -U --no-cache curl && \
    apk add -U --no-cache bash && \
    apk add -U --no-cache make && \
    apk add -U --no-cache git && \
    apk add -U --no-cache perl && \
    apk add -U --no-cache minisign
EOF

    DOCKER_BUILDKIT=0 docker build \
        -f "$tmpdir/Dockerfile.buildbase" \
        --build-arg TARGETARCH=s390x \
        --build-arg RELEASE="$release" \
        --build-arg MC_RELEASE="$mc_release" \
        -t "$build_base_image" \
        "$docker_context_dir"

    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run \
        --privileged \
        --network=host \
        --name "$container" \
        -e PATH="/usr/local/go/bin:/go/bin:${PATH}" \
        -e GOPATH=/go \
        -e CGO_ENABLED=0 \
        -e TARGETARCH=s390x \
        -e RELEASE="$release" \
        -e MC_RELEASE="$mc_release" \
        "$build_base_image" \
        sh -lc 'set -e
            cd /build
            git clone -b "$RELEASE" https://github.com/minio/minio.git
            cd minio
            make
            make install
            cp dockerscripts/download-static-curl.sh /build/download-static-curl
            cp dockerscripts/docker-entrypoint.sh /build/docker-entrypoint.sh
            cp CREDITS /build/CREDITS
            cp LICENSE /build/LICENSE
            chmod +x /go/bin/minio
            cd /build
            git clone -b "$MC_RELEASE" https://github.com/minio/mc.git
            cd mc
            make
            make install
            chmod +x /go/bin/mc
            cd /build
            chmod +x /build/download-static-curl
            /build/download-static-curl'

    docker commit "$container" "$build_image"
    docker rm -f "$container" >/dev/null 2>&1 || true

    {
        printf 'FROM %s AS build\n\n' "$build_image"
        sed -n '61,$p' "$docker_context_dir/Dockerfile"
    } > "$tmpdir/Dockerfile.final"

    DOCKER_BUILDKIT=0 docker build \
        -f "$tmpdir/Dockerfile.final" \
        --build-arg RELEASE="$release" \
        -t "$docker_image_tag" \
        "$docker_context_dir"

    rm -rf "$tmpdir"
}

function configureAndInstall() {
    printf -- '\nConfiguration and Installation started \n'
    # Install Java
    installJava

    export LANG="en_US.UTF-8"
    export JAVA_HOME=$ES_JAVA_HOME
    printf -- "export LANG="en_US.UTF-8"\n" >> "$BUILD_ENV"
    printf -- "export ES_JAVA_HOME=$ES_JAVA_HOME\n" >> "$BUILD_ENV"
    printf -- "export JAVA_HOME=$JAVA_HOME\n" >> "$BUILD_ENV"

    export PATH=$ES_JAVA_HOME/bin:$PATH
    printf -- "export PATH=$PATH\n" >> "$BUILD_ENV"
    java -version
    printf -- "Installation of %s is successful\n" "$JAVA_PROVIDED"
    buildMlCpp

    # Build JANSI v2.4.0 for auto-generation of credentials for the elastic user
    cd "$SOURCE_ROOT"
    rm -rf "$SOURCE_ROOT/jansi" "$SOURCE_ROOT/jansi-jar"
    git clone -b jansi-2.4.0 https://github.com/fusesource/jansi.git
    cd jansi
    make clean-native native OS_NAME=Linux OS_ARCH=s390x

    mkdir -p "$SOURCE_ROOT"/jansi-jar
    cd "$SOURCE_ROOT"/jansi-jar
    wget https://repo1.maven.org/maven2/org/fusesource/jansi/jansi/2.4.0/jansi-2.4.0.jar
    jar xvf jansi-2.4.0.jar
    cd org/fusesource/jansi/internal/native/Linux
    mkdir s390x
    cp "$SOURCE_ROOT"/jansi/target/native-Linux-s390x/libjansi.so s390x/
    cd "$SOURCE_ROOT"/jansi-jar
    jar cvf jansi-2.4.0.jar .

    mkdir -p "$SOURCE_ROOT"/.gradle/caches/modules-2/files-2.1/org.fusesource.jansi/jansi/2.4.0/321c614f85f1dea6bb08c1817c60d53b7f3552fd/
    cp jansi-2.4.0.jar "$SOURCE_ROOT"/.gradle/caches/modules-2/files-2.1/org.fusesource.jansi/jansi/2.4.0/321c614f85f1dea6bb08c1817c60d53b7f3552fd/
    sha256=$(sha256sum jansi-2.4.0.jar | awk '{print $1}')

    # Build osixia/light-baseimage image for osixia/openldap
    if docker image inspect osixia/light-baseimage:1.2.0 >/dev/null 2>&1; then
        printf -- 'Using existing osixia/light-baseimage:1.2.0 image.\n' |& tee -a "$LOG_FILE"
    else
        cd "$SOURCE_ROOT"
        rm -rf docker-light-baseimage
        git clone -b v1.2.0 https://github.com/osixia/docker-light-baseimage.git
        cd docker-light-baseimage/
        curl -sSL "${PATCH_URL}/docker-light-baseimage.patch" | git apply -
        DOCKER_BUILDKIT=0 make build
    fi

    # Build osixia/openldap image for openldap-fixture:1.0
    if docker image inspect osixia/openldap:1.4.0 >/dev/null 2>&1; then
        printf -- 'Using existing osixia/openldap:1.4.0 image.\n' |& tee -a "$LOG_FILE"
    else
        cd "$SOURCE_ROOT"
        rm -rf docker-openldap
        git clone -b v1.4.0 https://github.com/osixia/docker-openldap.git
        cd docker-openldap/
        curl -sSL "${PATCH_URL}/docker-openldap.patch" | git apply -
        DOCKER_BUILDKIT=0 make build
    fi

    # Build ZSTD v1.5.5 for starting Elasticsearch server
    cd "$SOURCE_ROOT"
    ZSTD_VERSION=1.5.5
    rm -rf "$SOURCE_ROOT/zstd-$ZSTD_VERSION" "$SOURCE_ROOT/zstd-native-dep"
    rm -f "v$ZSTD_VERSION.tar.gz"
    wget https://github.com/facebook/zstd/archive/refs/tags/v$ZSTD_VERSION.tar.gz
    tar -xzvf v$ZSTD_VERSION.tar.gz
    cd zstd-$ZSTD_VERSION
    # Compile libzstd.so library from source
    make -j$(nproc) lib
    make DESTDIR=$(pwd)/_build install

    cd "$SOURCE_ROOT"
    # Download and configure ElasticSearch
    printf -- 'Downloading Elasticsearch. Please wait.\n'
    rm -rf "$SOURCE_ROOT/elasticsearch"
    git clone --depth 1 -b v$PACKAGE_VERSION $ES_REPO_URL
    cd "$SOURCE_ROOT/elasticsearch"

    # Apply patch
    curl -sSL "${PATCH_URL}/elasticsearch.patch" | git apply -

    mkdir -p "$SOURCE_ROOT/elasticsearch/libs/"
    cp -r "$SOURCE_ROOT/zstd-$ZSTD_VERSION/_build/usr/local/lib/" "$SOURCE_ROOT/elasticsearch/libs/zstd/"
    export LD_LIBRARY_PATH=$SOURCE_ROOT/elasticsearch/libs/zstd/${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
    sudo ldconfig

    # Add libzstd.so object file to native libraries via zstd-1.5.5-linux-s390x.jar file
    cd "$SOURCE_ROOT"
    mkdir -p "$SOURCE_ROOT/zstd-native-dep/artifacts/linux-s390x/"
    cp "$SOURCE_ROOT/zstd-$ZSTD_VERSION/lib/libzstd.so" "$SOURCE_ROOT/zstd-$ZSTD_VERSION/LICENSE" "$SOURCE_ROOT/zstd-native-dep/artifacts/linux-s390x/"
    jar --create --no-manifest --file "$SOURCE_ROOT/zstd-native-dep/zstd-1.5.5-linux-s390x.jar" -C "$SOURCE_ROOT/zstd-native-dep/artifacts/" .
    sed -i "s#%S390X_ZSTD_DEP_DIR%#$SOURCE_ROOT/zstd-native-dep#" "$SOURCE_ROOT/elasticsearch/libs/native/libraries/build.gradle"

    # replace sha256sum of s390x jansi-2.4.0.jar
    sed -i 's|6cd91991323dd7b2fb28ca93d7ac12af5a86a2f53279e2b35827b30313fd0b9f|'"${sha256}"'|g' "${SOURCE_ROOT}/elasticsearch/gradle/verification-metadata.xml"

    createS390xGradleFile "packages/s390x-rpm"
    createS390xGradleFile "packages/s390x-deb"
    createS390xGradleFile "archives/linux-s390x-tar"
    createS390xGradleFile "docker/docker-s390x-export"

    # build openldap-fixture image for :x-pack:qa:openldap-tests:test
    if docker image inspect docker.elastic.co/elasticsearch-dev/openldap-fixture:1.0 >/dev/null 2>&1; then
        printf -- 'Using existing docker.elastic.co/elasticsearch-dev/openldap-fixture:1.0 image.\n' |& tee -a "$LOG_FILE"
    else
        cd "$SOURCE_ROOT/elasticsearch/x-pack/test/idp-fixture/src/main/resources/openldap/"
        DOCKER_BUILDKIT=0 docker build -f Dockerfile -t docker.elastic.co/elasticsearch-dev/openldap-fixture:1.0 .
    fi

    # build es-smb-fixture image for :x-pack:qa:third-party:active-directory:test
    if docker image inspect docker.elastic.co/elasticsearch-dev/es-smb-fixture:1.0 >/dev/null 2>&1; then
        printf -- 'Using existing docker.elastic.co/elasticsearch-dev/es-smb-fixture:1.0 image.\n' |& tee -a "$LOG_FILE"
    else
        cd "$SOURCE_ROOT/elasticsearch/x-pack/test/smb-fixture/src/main/resources"
        sed -i 's|^FROM ubuntu:24.04|FROM public.ecr.aws/docker/library/ubuntu:24.04|' Dockerfile
        sed -i '/^ENV TZ=/a ENV DEBIAN_FRONTEND=noninteractive' Dockerfile
        DOCKER_BUILDKIT=0 docker build -f Dockerfile -t docker.elastic.co/elasticsearch-dev/es-smb-fixture:1.0 . || buildS390xSmbFixtureImage "$PWD" "docker.elastic.co/elasticsearch-dev/es-smb-fixture:1.0"
    fi

    # build minio image for :modules:repository-s3:qa:third-party:test
    if docker image inspect minio/minio:RELEASE.2025-09-07T16-13-09Z >/dev/null 2>&1; then
        printf -- 'Using existing minio/minio:RELEASE.2025-09-07T16-13-09Z image.\n' |& tee -a "$LOG_FILE"
    else
        MINIO_RELEASE="RELEASE.2025-09-07T16-13-09Z"
        MINIO_MC_RELEASE="RELEASE.2025-08-13T08-35-41Z"
        cd "$SOURCE_ROOT"
        rm -rf "minio"
        mkdir -p "minio"
        cd "minio"
        wget -O Dockerfile "https://raw.githubusercontent.com/linux-on-ibm-z/dockerfile-examples/1297255f6d0b235c23b5eae2644fdd65584199a6/Minio/Dockerfile"
        sed -i 's|^FROM golang:1.24-alpine|FROM public.ecr.aws/docker/library/golang:1.24-alpine|' Dockerfile
        sed -i 's|COPY --from=build /go/bin/curl\* /usr/bin/|COPY --from=build /usr/bin/curl* /usr/bin/|' Dockerfile
        sed -i 's|go install aead.dev/minisign/cmd/minisign@v0.2.1|apk add -U --no-cache minisign|' Dockerfile
        docker image inspect public.ecr.aws/docker/library/golang:1.24-alpine >/dev/null 2>&1 \
            || docker pull public.ecr.aws/docker/library/golang:1.24-alpine \
            || { docker pull mirror.gcr.io/library/golang:1.24-alpine && docker tag mirror.gcr.io/library/golang:1.24-alpine public.ecr.aws/docker/library/golang:1.24-alpine; }
        if [[ "$(uname -m)" == "s390x" ]]; then
            buildS390xMinioImage "$PWD" "minio/minio:${MINIO_RELEASE}" "$MINIO_RELEASE" "$MINIO_MC_RELEASE"
        else
            DOCKER_BUILDKIT=0 docker build --build-arg TARGETARCH=s390x --build-arg RELEASE="$MINIO_RELEASE" --build-arg MC_RELEASE="$MINIO_MC_RELEASE" -t "minio/minio:${MINIO_RELEASE}" .
        fi
    fi

    cd "$SOURCE_ROOT/elasticsearch"

    # Building Elasticsearch
    printf -- 'Building Elasticsearch \n'
    printf -- 'Build might take some time. Sit back and relax\n'
    export GRADLE_USER_HOME=$SOURCE_ROOT/.gradle
    export DOCKER_BUILDKIT=0
    printf -- "export GRADLE_USER_HOME=$GRADLE_USER_HOME\n" >> "$BUILD_ENV"
    printf -- "export DOCKER_BUILDKIT=$DOCKER_BUILDKIT\n" >> "$BUILD_ENV"
    printf -- "export ES9_OPTS=\"$ES9_OPTS\"\n" >> "$BUILD_ENV"

    ./gradlew :distribution:archives:linux-s390x-tar:assemble $ES9_OPTS $ML_CPP_GRADLE_OPTS --max-workers="$CPU_NUM" --parallel | tee "$LOG_FILE"

    # Verifying Elasticsearch installation
    if grep -q "BUILD FAILED" "$LOG_FILE"; then
        printf -- '\nBuild failed due to some unknown issues.\n'
        exit 1
    fi

    printf -- 'Built Elasticsearch successfully. \n\n'

    if [[ $BUILD_TAR_ONLY == "true" ]]; then
        echo "User requested to build tar distribution only. Exiting..."
        exit 0
    fi

    printf -- 'Creating distributions as deb, rpm and docker: \n\n'
    ./gradlew :distribution:packages:s390x-deb:assemble $ES9_OPTS $ML_CPP_GRADLE_OPTS
    printf -- 'Created deb distribution. \n\n'
    ./gradlew :distribution:packages:s390x-rpm:assemble $ES9_OPTS $ML_CPP_GRADLE_OPTS
    printf -- 'Created rpm distribution. \n\n'
    buildS390xDockerDistribution
    printf -- 'Created docker distribution. \n\n'

    printf -- "\n\nInstalling Elasticsearch\n"

    cd "${SOURCE_ROOT}/elasticsearch"
    sudo rm -rf /usr/share/elasticsearch
    sudo mkdir -p /usr/share/elasticsearch
    sudo tar -xzf distribution/archives/linux-s390x-tar/build/distributions/elasticsearch-"${PACKAGE_VERSION}"-SNAPSHOT-linux-s390x.tar.gz -C /usr/share/elasticsearch --strip-components 1
    sudo ln -sf /usr/share/elasticsearch/bin/* /usr/bin/

    if ! getent group elastic >/dev/null; then
        printf -- '\nCreating group elastic.\n'
        sudo /usr/sbin/groupadd elastic || true
    fi
    ES_OWNER="${NON_ROOT_USER:-$(id -un)}"
    ES_GROUP="elastic"
    getent group "$ES_GROUP" >/dev/null || ES_GROUP="$(id -gn "$ES_OWNER" 2>/dev/null || id -gn)"
    sudo chown "$ES_OWNER:$ES_GROUP" -R /usr/share/elasticsearch

    # Verifying Elasticsearch installation
    if command -v "$PACKAGE_NAME" >/dev/null; then
        printf -- "%s installation completed.\n" "$PACKAGE_NAME"
    else
        printf -- "Error while installing %s. Exiting...\n" "$PACKAGE_NAME"
        exit 127
    fi

    # Run tests
    runTest
}

function runTest() {
    if [[ "$TESTS" == "true" ]]; then
        export JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF8"
        grep -q "JAVA_TOOL_OPTIONS" "$BUILD_ENV" || printf -- "export JAVA_TOOL_OPTIONS=$JAVA_TOOL_OPTIONS\n" >> "$BUILD_ENV"
        # Always set RUNTIME_JAVA_HOME=/opt/java/jdk to make sure that the tests use it when using the distro provided OpenJDK.
        # This works around a gradle problem where gradle does not recognize the distro provided OpenJDK.
        export RUNTIME_JAVA_HOME=/opt/java/jdk
        grep -q "RUNTIME_JAVA_HOME" "$BUILD_ENV" || printf -- "export RUNTIME_JAVA_HOME=$RUNTIME_JAVA_HOME\n" >> "$BUILD_ENV"
        configureMlCppRepo

        cd "${SOURCE_ROOT}/elasticsearch"
        set +e
        # Run the full Elasticsearch test suite with the same s390x constraints used for manual verification.
        printf -- '\n Running Elasticsearch test suite.\n'
        ./gradlew --continue \
            test \
            internalClusterTest \
            $ES9_OPTS \
            $ML_CPP_GRADLE_OPTS \
            -Dtests.haltonfailure=false \
            -Dtests.jvm.argline="-Xss2m -Xmx2g" \
            -Dtests.jvms=1 \
            --max-workers=1 \
            |& tee -a "${SOURCE_ROOT}/logs/test_results_${JAVA_PROVIDED}.log"

        printf -- '*****************************************************************************************************\n'
        printf -- 'Some test cases may still require platform-specific investigation on s390x.\n\n'
        printf -- 'Individual tests can be rerun with a command like:\n'
        printf -- '  ./gradlew :x-pack:plugin:ml:test --tests "org.elasticsearch.xpack.ml.inference.adaptiveallocations.AdaptiveAllocationsScalerServiceTests" $ES9_OPTS $ML_CPP_GRADLE_OPTS -Dtests.haltonfailure=false -Dtests.jvm.argline="-Xss2m -Xmx2g" -Dtests.jvms=1 --max-workers=1\n\n'
        printf -- "Note: Environment Variables needed for rerunning tests have been added to $HOME/setenv.sh\n"
        printf -- "      To set the Environment Variables needed to rerun tests, please run: source $HOME/setenv.sh \n"
        printf -- '*****************************************************************************************************\n'
        set -e
    fi
}

function logDetails() {
    printf -- 'SYSTEM DETAILS\n' >"$LOG_FILE"
    if [ -f "/etc/os-release" ]; then
        cat "/etc/os-release" >>"$LOG_FILE"
    fi

    cat /proc/version >>"$LOG_FILE"
    printf -- "\nDetected %s \n" "$PRETTY_NAME"
    printf -- "Request details : PACKAGE NAME= %s , VERSION= %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" |& tee -a "$LOG_FILE"
}

# Print the usage message
function printHelp() {
    echo
    echo "Usage: "
    echo "  bash build_elasticsearch.sh [-d debug] [-y install-without-confirmation] [-t install-with-tests]"
    echo "  ML_CPP_REPO=/tmp/mlcpp-ivy ML_CPP_REF=v9.3.3 bash build_elasticsearch.sh [-y]"
    echo "  ML_CPP_FORCE_REBUILD=true bash build_elasticsearch.sh [-y]"
    echo "  ML_PYTORCH_ROOT=/path/to/pytorch-gcc13 bash build_elasticsearch.sh [-y]"
    echo "  ML_PYTORCH_SOURCE_DIR=/tmp/pytorch ML_PYTORCH_BUILD_PARALLEL_LEVEL=4 bash build_elasticsearch.sh [-y]"
    echo
}

while getopts "h?dytk" opt; do
    case "$opt" in
    h | \?)
        printHelp
        exit 0
        ;;
    d)
        set -x
        ;;
    y)
        FORCE="true"
        ;;
    t)
        TESTS="true"
        if command -v "$PACKAGE_NAME" >/dev/null; then
            esversion=$(elasticsearch --version |& sed -En 's/Version:\s+([0-9.]+).*/\1/p')
            printf -- "%s is detected with version %s .\n" "$PACKAGE_NAME" "$esversion" |& tee -a "$LOG_FILE"
            source "$HOME/setenv.sh"
            runTest |& tee -a "$LOG_FILE"
            exit 0
        fi
        ;;
    k)
        BUILD_TAR_ONLY="true"
        ;;
    esac
done

function printSummary() {
    printf -- '\n*****************************************************************************************************\n'
    printf -- "\n* Getting Started * \n"
    printf -- "Note: Environment Variables needed have been added to $HOME/setenv.sh\n"
    printf -- "      To set the Environment Variables needed for Elasticsearch, please run: source $HOME/setenv.sh \n"
    printf -- '\n\nStart Elasticsearch using the following command: elasticsearch '
    printf -- '\n*****************************************************************************************************\n'
}

logDetails
prepare

printf -- "Installing %s %s for %s and %s\n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" "$JAVA_PROVIDED" |& tee -a "$LOG_FILE"
printf -- "Installing dependencies... it may take some time.\n"

case "$DISTRO" in
"rhel-8.10" | "rhel-9.4" | "rhel-9.6" | "rhel-9.7")
    ALLOWERASING=""
    if [[ $DISTRO != "rhel-8.10" ]]; then
        ALLOWERASING="--allowerasing"
    fi
    RHEL_PACKAGES=(curl git gzip tar bzip2 wget patch make gcc gcc-c++ gcc-toolset-13-gcc gcc-toolset-13-gcc-c++ cmake zip unzip zlib-devel libxml2-devel python3 python3-devel)
    MISSING_RHEL_PACKAGES=()
    for package in "${RHEL_PACKAGES[@]}"; do
        if ! rpm -q "$package" >/dev/null 2>&1; then
            MISSING_RHEL_PACKAGES+=("$package")
        fi
    done
    if (( ${#MISSING_RHEL_PACKAGES[@]} > 0 )); then
        if ! sudo yum install -y $ALLOWERASING "${MISSING_RHEL_PACKAGES[@]}" |& tee -a "$LOG_FILE"; then
            printf -- 'Retrying dependency installation with supplementary repositories disabled.\n' |& tee -a "$LOG_FILE"
            sudo yum install -y $ALLOWERASING --disablerepo='*supplementary*' "${MISSING_RHEL_PACKAGES[@]}" |& tee -a "$LOG_FILE"
        fi
    else
        printf -- 'Required RHEL packages are already installed; skipping yum install.\n' |& tee -a "$LOG_FILE"
    fi
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;

"sles-15.7")
    sudo zypper install -y curl git gzip tar wget patch make gcc gcc-c++ cmake zip unzip zlib-devel libxml2-devel fontconfig dejavu-fonts gawk python3 python3-devel python3-pip ninja | tee -a "$LOG_FILE"
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;

"ubuntu-22.04" | "ubuntu-24.04")
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl git gzip tar wget patch locales make gcc g++ cmake zip unzip zlib1g-dev libxml2-dev python3 python3-dev python3-pip ninja-build |& tee -a "$LOG_FILE"
    sudo locale-gen en_US.UTF-8
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;

*)
    printf -- "%s not supported \n" "$DISTRO" |& tee -a "$LOG_FILE"
    exit 1
    ;;
esac

cleanup
printSummary |& tee -a "$LOG_FILE"
