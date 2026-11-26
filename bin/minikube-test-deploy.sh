#!/bin/bash
#
# Deploys Phrasea with its Helm chart on a local minikube cluster, then checks the deployment.
# See the README of this repository, or run it with --help.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_DIR=$(pwd)

PROFILE=${MINIKUBE_PROFILE:-phrasea}
CPUS=${MINIKUBE_CPUS:-6}
MEMORY=${MINIKUBE_MEMORY:-14g}
DISK_SIZE=${MINIKUBE_DISK_SIZE:-60g}
DRIVER=${MINIKUBE_DRIVER:-docker}
K8S_VERSION=${MINIKUBE_KUBERNETES_VERSION:-stable}
DOMAIN=${PHRASEA_MINIKUBE_DOMAIN:-phrasea.minikube}
NAMESPACE=${PHRASEA_NAMESPACE:-phrasea}
RELEASE=${PHRASEA_RELEASE:-phrasea}
CHART=${PHRASEA_CHART:-}
INGRESS=${PHRASEA_INGRESS:-traefik}
TRAEFIK_CHART_VERSION=${TRAEFIK_CHART_VERSION:-}
IMAGES=${PHRASEA_IMAGES:-local}
IMAGE_REGISTRY=${PHRASEA_IMAGE_REGISTRY:-alchemyfr}
IMAGE_TAG=${PHRASEA_IMAGE_TAG:-}
PHRASEA_DIR=${PHRASEA_SOURCE_DIR:-}
IMPORT_FIXTURES=${PHRASEA_IMPORT_FIXTURES:-no}
MAILPIT=${PHRASEA_MAILPIT:-yes}
UPGRADE_TEST=${PHRASEA_UPGRADE_TEST:-yes}
EDIT_HOSTS=${PHRASEA_EDIT_HOSTS:-yes}
HELM_TIMEOUT=${PHRASEA_HELM_TIMEOUT:-45m}
EXTRA_VALUES=()
ASSUME_YES=0
COMMAND=up

CURL_IMAGE=curlimages/curl:8.11.1

if [ -t 1 ]; then
  C_BOLD=$'\e[1m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_RESET=$'\e[0m'
else
  C_BOLD=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_RESET=
fi

function usage {
  cat <<EOF
Usage: $0 [command] [options]

Deploys Phrasea with its Helm chart on a local minikube cluster and checks the deployment.
Every setting is asked interactively (current value as default), then each step is
confirmed before it runs ([Y]es / [s]kip / [q]uit).

Commands:
  up        Configure minikube, deploy the stack and run the checks (default)
  test      Run the checks against an already deployed stack
  status    Show the release, pods and ingresses
  down      Uninstall the release and delete its namespace (data included)
  destroy   Delete the minikube profile (and optionally the generated secrets)

Options:
  -y, --yes            Non-interactive: keep the defaults/env values, run every step
  -f, --values FILE    Extra Helm values file, applied last (repeatable). The generated
                       values target the chart 3.x: add the missing ones for an older chart
  -h, --help           Show this help

Settings (env var = default):
  MINIKUBE_PROFILE=${PROFILE}  MINIKUBE_CPUS=${CPUS}  MINIKUBE_MEMORY=${MEMORY}
  MINIKUBE_DISK_SIZE=${DISK_SIZE}  MINIKUBE_DRIVER=${DRIVER}  MINIKUBE_KUBERNETES_VERSION=${K8S_VERSION}
  PHRASEA_MINIKUBE_DOMAIN=${DOMAIN}  PHRASEA_NAMESPACE=${NAMESPACE}  PHRASEA_RELEASE=${RELEASE}
  PHRASEA_CHART       local chart directory, or a released chart version (e.g. 2.27.0);
                      defaults to charts/phrasea of this repository
  PHRASEA_INGRESS=${INGRESS}  (traefik: installed with Helm | nginx: minikube addon)
  TRAEFIK_CHART_VERSION  Traefik Helm chart version (latest when empty)
  PHRASEA_IMAGES=${IMAGES}  (registry: pull IMAGE_REGISTRY/ps-*:IMAGE_TAG | local: build them in minikube)
  PHRASEA_IMAGE_REGISTRY=${IMAGE_REGISTRY}  PHRASEA_IMAGE_TAG ("minikube" for local images, latest otherwise)
  PHRASEA_SOURCE_DIR  Phrasea checkout the local images are built from (default: ../phrasea)
  PHRASEA_IMPORT_FIXTURES=${IMPORT_FIXTURES}  PHRASEA_MAILPIT=${MAILPIT}  PHRASEA_UPGRADE_TEST=${UPGRADE_TEST}
  PHRASEA_EDIT_HOSTS=${EDIT_HOSTS}  (add the domains to /etc/hosts with sudo)
  PHRASEA_HELM_TIMEOUT=${HELM_TIMEOUT}
  PHRASEA_MINIKUBE_DIR  where the chart copy, values and secrets are kept
                        (default: \${XDG_STATE_HOME:-~/.local/state}/phrasea-minikube/<profile>)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    up|test|status|down|destroy) COMMAND=$1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -f|--values)
      [ $# -ge 2 ] || { echo "Missing file after $1" >&2; exit 1; }
      EXTRA_VALUES+=("$(realpath "$2")"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

function info { echo "${C_BLUE}[i]${C_RESET} $*"; }
function ok { echo "${C_GREEN}[✓]${C_RESET} $*"; }
function warn { echo "${C_YELLOW}[!]${C_RESET} $*" >&2; }
function die { echo "${C_RED}[✗]${C_RESET} $*" >&2; exit 1; }
function title { echo; echo "${C_BOLD}==> $*${C_RESET}"; }

function kc { kubectl --context "${PROFILE}" "$@"; }
function hm { helm --kube-context "${PROFILE}" "$@"; }

if [ "${ASSUME_YES}" = 0 ] && ! [ -r /dev/tty ]; then
  die "No terminal to ask the questions: run with --yes"
fi

function prompt {
  local answer
  read -r -p "$1" answer < /dev/tty
  printf '%s' "${answer}"
}

# ask VAR "Label" [allowed values…]: asks a value, the current one being the default.
function ask {
  local var=$1 label=$2 answer
  shift 2
  [ "${ASSUME_YES}" = 1 ] && return 0
  while true; do
    answer=$(prompt "  ${label}$([ $# -gt 0 ] && echo " ($(IFS=/; echo "$*"))") [${!var}]: ")
    answer=${answer:-${!var}}
    if [ $# -eq 0 ] || [[ " $* " == *" ${answer} "* ]]; then
      printf -v "${var}" '%s' "${answer}"
      return 0
    fi
    warn "Expected one of: $*"
  done
}

# confirm "Question": yes/no, yes by default.
function confirm {
  [ "${ASSUME_YES}" = 1 ] && return 0
  case "$(prompt "$1 [Y/n] ")" in
    ''|[yYoO]*) return 0 ;;
    *) return 1 ;;
  esac
}

# step "Description": announces a step; returns 1 when the user skips it.
function step {
  title "$1"
  [ "${ASSUME_YES}" = 1 ] && return 0
  while true; do
    case "$(prompt "Run this step? [Y]es / [s]kip / [q]uit ")" in
      ''|[yYoO]*) return 0 ;;
      [sS]*) warn "Skipped: $1"; return 1 ;;
      [qQ]*) echo "Aborted."; exit 130 ;;
    esac
  done
}

# ask_matching VAR "Label" REGEX "description": asks again until the value matches REGEX.
function ask_matching {
  local var=$1 label=$2 regex=$3 expected=$4 previous
  while true; do
    previous=${!var}
    ask "${var}" "${label}"
    [[ "${!var}" =~ ${regex} ]] && return 0
    [ "${ASSUME_YES}" = 1 ] && die "Invalid ${label}: \"${!var}\", expected ${expected}"
    warn "Expected ${expected}"
    printf -v "${var}" '%s' "${previous}"
  done
}

# ask_size VAR "Label": a size as minikube reads it. A bare number is taken as gigabytes,
# where minikube would read megabytes.
function ask_size {
  local var=$1 label=$2 previous
  while true; do
    previous=${!var}
    ask "${var}" "${label}"
    if [[ "${!var}" =~ ^[0-9]+$ ]]; then
      printf -v "${var}" '%sg' "${!var}"
      info "No unit given, read as gigabytes: ${!var}"
    fi
    [[ "${!var}" =~ ^[0-9]+(\.[0-9]+)?[kKmMgGtT][bB]?$ ]] && return 0
    [ "${ASSUME_YES}" = 1 ] && die "Invalid ${label}: \"${!var}\", expected a size such as 14g or 16384m"
    warn "Expected a size such as 14g or 16384m"
    printf -v "${var}" '%s' "${previous}"
  done
}

function is_yes { [[ "$1" =~ ^([yY]|[yY]es|[oO]|[oO]ui|true|1)$ ]]; }

function require_tools {
  local missing=() tool
  for tool in "$@"; do
    command -v "${tool}" > /dev/null || missing+=("${tool}")
  done
  [ ${#missing[@]} -eq 0 ] || die "Missing tools: ${missing[*]}"
}

function default_chart {
  local local_chart="${REPO_DIR}/charts/phrasea"
  if [ -f "${local_chart}/Chart.yaml" ]; then
    realpath "${local_chart}"
    return
  fi
  curl -fsSL https://api.github.com/repos/alchemy-fr/phrasea-helm-charts/releases/latest 2> /dev/null \
    | sed -n 's/.*"tag_name": *"phrasea-\([^"]*\)".*/\1/p' | head -n1
}

function set_work_dir {
  WORK_DIR=${PHRASEA_MINIKUBE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/phrasea-minikube/${PROFILE}}
  SECRETS_FILE="${WORK_DIR}/secrets.yaml"
  VALUES_FILE="${WORK_DIR}/values.yaml"
  CHART_DIR="${WORK_DIR}/chart/phrasea"
  TLS_DIR="${WORK_DIR}/tls"
}

function configure {
  title "Settings"
  [ -n "${CHART}" ] || CHART=$(default_chart)
  while true; do
    ask PROFILE "Minikube profile"
    ask DRIVER "Minikube driver"
    ask_matching CPUS "CPUs given to minikube" '^([0-9]+|max)$' "a number of CPUs, or max"
    ask_size MEMORY "Memory given to minikube"
    ask_size DISK_SIZE "Disk size of minikube"
    ask K8S_VERSION "Kubernetes version"
    ask DOMAIN "Domain of the stack"
    ask NAMESPACE "Kubernetes namespace"
    ask RELEASE "Helm release name"
    ask CHART "Helm chart (local directory or released version)"
    ask INGRESS "Ingress controller" traefik nginx
    ask IMAGES "Phrasea images" registry local
    if [ "${IMAGES}" = local ]; then
      [ -n "${PHRASEA_DIR}" ] || PHRASEA_DIR=$(realpath -m "${REPO_DIR}/../phrasea")
      ask PHRASEA_DIR "Phrasea source directory (images built from it)"
      PHRASEA_DIR=${PHRASEA_DIR/#\~/${HOME}}
      while [ ! -x "${PHRASEA_DIR}/bin/build.sh" ]; do
        [ "${ASSUME_YES}" = 1 ] && die "No bin/build.sh in ${PHRASEA_DIR}: set PHRASEA_SOURCE_DIR to a Phrasea checkout"
        warn "No bin/build.sh in ${PHRASEA_DIR}"
        ask PHRASEA_DIR "Phrasea source directory (images built from it)"
        PHRASEA_DIR=${PHRASEA_DIR/#\~/${HOME}}
      done
      PHRASEA_DIR=$(realpath "${PHRASEA_DIR}")
    fi
    default_image_tag
    ask IMAGE_REGISTRY "Image registry namespace"
    ask IMAGE_TAG "Image tag"
    ask IMPORT_FIXTURES "Import the databox fixtures" yes no
    ask MAILPIT "Deploy Mailpit to catch the emails" yes no
    ask UPGRADE_TEST "Test a helm upgrade (migrations) after the install" yes no
    ask EDIT_HOSTS "Add the domains to /etc/hosts (sudo)" yes no
    ask HELM_TIMEOUT "Helm timeout"

    set_work_dir
    [ -n "${CHART}" ] || die "No chart found: set PHRASEA_CHART to a chart directory or a released version"

    cat <<EOF

${C_BOLD}Summary${C_RESET}
  minikube    profile=${PROFILE} driver=${DRIVER} cpus=${CPUS} memory=${MEMORY} disk=${DISK_SIZE} k8s=${K8S_VERSION}
  stack       https://*.${DOMAIN}  namespace=${NAMESPACE}  release=${RELEASE}
  chart       ${CHART}
  ingress     ${INGRESS}$([ "${INGRESS}" = traefik ] && echo " (Helm chart ${TRAEFIK_CHART_VERSION:-latest})")
  images      ${IMAGE_REGISTRY}/ps-*:${IMAGE_TAG} ($([ "${IMAGES}" = local ] && echo "built in minikube from ${PHRASEA_DIR}" || echo "pulled"))
  options     fixtures=${IMPORT_FIXTURES} mailpit=${MAILPIT} upgrade-test=${UPGRADE_TEST} /etc/hosts=${EDIT_HOSTS} timeout=${HELM_TIMEOUT}
  extra       ${EXTRA_VALUES[*]:-(no extra values file)}
  work dir    ${WORK_DIR}

EOF
    confirm "Use these settings?" && break
    echo "Let's change them."
  done
}

function start_minikube {
  step "Start minikube (profile ${PROFILE})" || return 0

  local host_status
  host_status=$(minikube -p "${PROFILE}" status --format '{{.Host}}' 2> /dev/null || true)
  case "${host_status}" in
    Running)
      ok "minikube ${PROFILE} is already running (its CPU/memory settings are kept)"
      ;;
    Stopped|Paused)
      info "Starting the existing minikube ${PROFILE} (its CPU/memory settings are kept)"
      minikube start -p "${PROFILE}"
      ;;
    *)
      minikube start -p "${PROFILE}" \
        --driver="${DRIVER}" \
        --cpus="${CPUS}" \
        --memory="${MEMORY}" \
        --disk-size="${DISK_SIZE}" \
        --kubernetes-version="${K8S_VERSION}" \
        --addons=storage-provisioner,default-storageclass,metrics-server
      ;;
  esac

  kc wait --for=condition=Ready node --all --timeout=300s > /dev/null
  ok "minikube ${PROFILE} is up ($(minikube -p "${PROFILE}" ip))"
}

function install_ingress {
  step "Install the ${INGRESS} ingress controller" || return 0

  if [ "${INGRESS}" = traefik ]; then
    helm repo add traefik https://traefik.github.io/charts --force-update > /dev/null
    # hostPort exposes the entrypoints on the minikube IP, as the minikube ingress addon does.
    hm upgrade --install traefik traefik/traefik \
      --namespace traefik --create-namespace \
      ${TRAEFIK_CHART_VERSION:+--version "${TRAEFIK_CHART_VERSION}"} \
      --set service.spec.type=ClusterIP \
      --set ports.web.hostPort=80 \
      --set ports.websecure.hostPort=443 \
      --set ports.websecure.transport.respondingTimeouts.readTimeout=600s \
      --set ingressClass.isDefaultClass=false \
      --wait --timeout 10m
  else
    minikube -p "${PROFILE}" addons enable ingress
    kc -n ingress-nginx wait --for=condition=Available deploy/ingress-nginx-controller --timeout=600s
  fi
  ok "Ingress controller ${INGRESS} ready"
}

function ingress_cluster_ip {
  if [ "${INGRESS}" = traefik ]; then
    kc -n traefik get svc traefik -o jsonpath='{.spec.clusterIP}'
  else
    kc -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}'
  fi
}

# The pods reach the public URLs (Keycloak, MinIO…) through the ingress controller: CoreDNS
# answers its ClusterIP for every name of the domain.
function configure_cluster_dns {
  step "Resolve *.${DOMAIN} to the ingress controller inside the cluster (CoreDNS)" || return 0

  local ip corefile start end
  ip=$(ingress_cluster_ip)
  [ -n "${ip}" ] || die "Ingress controller service not found: install it first"
  start="# <phrasea:${DOMAIN}>"
  end="# </phrasea:${DOMAIN}>"

  corefile=$(kc -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' \
    | START="${start}" END="${end}" awk '
        $0 == ENVIRON["START"] { skip = 1; next }
        skip { if ($0 == ENVIRON["END"]) skip = 0; next }
        { print }
      ')
  corefile+=$(cat <<EOF

${start}
${DOMAIN}:53 {
    errors
    template IN A {
        answer "{{ .Name }} 60 IN A ${ip}"
    }
    template ANY ANY {
        rcode NOERROR
    }
}
${end}
EOF
)
  kc -n kube-system create configmap coredns --from-literal=Corefile="${corefile}" --dry-run=client -o yaml \
    | kc -n kube-system replace -f - > /dev/null
  kc -n kube-system rollout restart deploy/coredns > /dev/null
  kc -n kube-system rollout status deploy/coredns --timeout=180s > /dev/null
  ok "*.${DOMAIN} → ${ip} inside the cluster"
}

function create_certificate {
  step "Create the wildcard TLS certificate *.${DOMAIN}" || return 0

  mkdir -p "${TLS_DIR}"
  local crt="${TLS_DIR}/${DOMAIN}.pem" key="${TLS_DIR}/${DOMAIN}-key.pem"
  if [ -f "${crt}" ] && openssl x509 -in "${crt}" -noout -checkend 604800 > /dev/null 2>&1; then
    ok "Certificate already present: ${crt}"
    return 0
  fi

  if command -v mkcert > /dev/null; then
    mkcert -key-file "${key}" -cert-file "${crt}" "*.${DOMAIN}" "${DOMAIN}"
    info "Run \"mkcert -install\" once if your browser does not trust the mkcert CA yet"
  else
    warn "mkcert not found: self-signed certificate (browsers will warn)"
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=*.${DOMAIN}" \
      -addext "subjectAltName=DNS:*.${DOMAIN},DNS:${DOMAIN}" -keyout "${key}" -out "${crt}" 2> /dev/null
  fi
  ok "Certificate written to ${crt}"
}

function build_local_images {
  [ "${IMAGES}" = local ] || return 0
  step "Build the Phrasea images in the minikube Docker daemon (${IMAGE_REGISTRY}/ps-*:${IMAGE_TAG})" || return 0

  (
    cd "${PHRASEA_DIR}"
    eval "$(minikube -p "${PROFILE}" docker-env)"
    export COMPOSE_FILE=docker-compose.yml
    # The profiles of the images the chart deploys, whatever the .env.local of the checkout enables.
    export COMPOSE_PROFILES=databox,expose,uploader,dashboard,configurator,matomo
    export REGISTRY_NAMESPACE="${IMAGE_REGISTRY}/ps-"
    export DOCKER_TAG="${IMAGE_TAG}"
    bin/build.sh
  )
  ok "Images built in minikube"
}

function default_image_tag {
  [ -n "${IMAGE_TAG}" ] && return 0
  if [ "${IMAGES}" = local ]; then IMAGE_TAG=minikube; else IMAGE_TAG=latest; fi
}

function random_secret { openssl rand -hex "${1:-16}"; }

# libsodium crypto_box key pair (X25519), base64 encoded as the databox API expects.
function sodium_key_pair {
  local pem
  pem=$(openssl genpkey -algorithm X25519)
  SODIUM_SECRET=$(openssl pkey -outform DER <<< "${pem}" | tail -c 32 | base64)
  SODIUM_PUBLIC=$(openssl pkey -pubout -outform DER <<< "${pem}" | tail -c 32 | base64)
}

function write_values {
  step "Write the Helm values (secrets are generated once and kept)" || return 0
  mkdir -p "${WORK_DIR}"

  if [ -f "${SECRETS_FILE}" ]; then
    ok "Keeping the secrets of ${SECRETS_FILE}"
  else
    sodium_key_pair
    (
      umask 077
      cat > "${SECRETS_FILE}" <<EOF
# Generated by bin/minikube-test-deploy.sh: keep it as long as the release (and its volumes) exists.
keycloak:
  masterAdmin:
    password: "$(random_secret)"
  defaultAdmin:
    password: "$(random_secret 8)"
databox:
  adminOAuthClient:
    secret: "$(random_secret)"
  appSecret:
    value: "$(random_secret 32)"
  api:
    config:
      secrets:
        publicKey: "${SODIUM_PUBLIC}"
        secretKey: "${SODIUM_SECRET}"
expose:
  adminOAuthClient:
    secret: "$(random_secret)"
  appSecret:
    value: "$(random_secret 32)"
uploader:
  adminOAuthClient:
    secret: "$(random_secret)"
  appSecret:
    value: "$(random_secret 32)"
postgresql:
  password: "$(random_secret)"
rabbitmq:
  password: "$(random_secret)"
minio:
  accessKey: "$(random_secret 12)"
  secretKey: "$(random_secret)"
elasticsearch:
  secret:
    password: "$(random_secret)"
  password: "$(random_secret)"
sockudo:
  key: "$(random_secret)"
  secret: "$(random_secret)"
mailpit:
  auth: "admin:$(random_secret 8)"
EOF
    )
    ok "Secrets generated in ${SECRETS_FILE}"
  fi

  default_image_tag
  local crt="${TLS_DIR}/${DOMAIN}.pem" key="${TLS_DIR}/${DOMAIN}-key.pem"
  [ -f "${crt}" ] && [ -f "${key}" ] || die "Missing TLS certificate ${crt}: run the certificate step"

  cat > "${VALUES_FILE}" <<EOF
# Generated by bin/minikube-test-deploy.sh at each run.
repository:
  baseUrl: "${IMAGE_REGISTRY}"
  tag: "${IMAGE_TAG}"
  imagePullPolicy: $([ "${IMAGES}" = local ] || [ "${IMAGE_TAG}" != latest ] && echo IfNotPresent || echo Always)
stack:
  name: minikube
  domain: "${DOMAIN}"
ingress:
  className: "${INGRESS}"
  tls:
    wildcard:
      enabled: true
      crt: |
$(sed 's/^/        /' "${crt}")
      key: |
$(sed 's/^/        /' "${key}")
security:
  verifySsl: false
  verifyHost: false
keycloak:
  defaultAdmin:
    username: admin
    email: "admin@${DOMAIN}"
    passwordIsDefinitive: true
databox:
  importFixtures: $(is_yes "${IMPORT_FIXTURES}" && echo true || echo false)
mailpit:
  enabled: $(is_yes "${MAILPIT}" && echo true || echo false)
EOF
  ok "Values written to ${VALUES_FILE}"
}

# Copies the chart into the work dir. The private phrasea-parade dependency (ECR) is dropped
# when it is not vendored: Helm refuses a chart with a missing dependency, even a disabled one.
function prepare_chart {
  step "Prepare the Helm chart (${CHART})" || return 0

  rm -rf "${WORK_DIR}/chart"
  mkdir -p "${WORK_DIR}/chart"
  if [ -d "${CHART}" ]; then
    cp -a "$(realpath "${CHART}")" "${CHART_DIR}"
  else
    helm pull "https://github.com/alchemy-fr/phrasea-helm-charts/releases/download/phrasea-${CHART}/phrasea-${CHART}.tgz" \
      --untar --untardir "${WORK_DIR}/chart"
  fi
  [ -f "${CHART_DIR}/Chart.yaml" ] || die "No Chart.yaml in ${CHART_DIR}"

  if grep -q 'name: *phrasea-parade' "${CHART_DIR}/Chart.yaml" && ! compgen -G "${CHART_DIR}/charts/phrasea-parade*" > /dev/null; then
    awk '
      function flush() { if (!index(item, "name: phrasea-parade")) printf "%s", item; item = "" }
      /^dependencies:/ { print; deps = 1; next }
      deps && /^[^ #-]/ { flush(); deps = 0 }
      deps && /^ *- / { flush() }
      deps { item = item $0 "\n"; next }
      { print }
      END { flush() }
    ' "${CHART_DIR}/Chart.yaml" > "${CHART_DIR}/Chart.yaml.tmp"
    mv "${CHART_DIR}/Chart.yaml.tmp" "${CHART_DIR}/Chart.yaml"
    rm -f "${CHART_DIR}/Chart.lock"
    info "Dropped the phrasea-parade dependency (not vendored, parade stays disabled)"
  fi

  if helm dependency list "${CHART_DIR}" 2> /dev/null | awk 'NR > 1 && NF && $NF != "ok" && $NF != "unpacked"' | grep -q .; then
    helm repo add elastic https://helm.elastic.co --force-update > /dev/null
    helm dependency update "${CHART_DIR}"
  fi

  local values_args=(-f "${SECRETS_FILE}" -f "${VALUES_FILE}")
  for f in "${EXTRA_VALUES[@]}"; do values_args+=(-f "${f}"); done
  helm lint "${CHART_DIR}" "${values_args[@]}" > "${WORK_DIR}/lint.log" 2>&1 \
    || { cat "${WORK_DIR}/lint.log"; die "helm lint failed"; }
  helm template "${RELEASE}" "${CHART_DIR}" -n "${NAMESPACE}" "${values_args[@]}" > "${WORK_DIR}/manifests.yaml" \
    || die "helm template failed"

  if [ "${IMAGES}" = local ]; then
    local missing
    missing=$(comm -23 \
      <(grep -o "image: *\"\{0,1\}${IMAGE_REGISTRY}/ps-[^\" ]*:${IMAGE_TAG}" "${WORK_DIR}/manifests.yaml" | sed 's/^image: *"\{0,1\}//' | sort -u) \
      <(minikube -p "${PROFILE}" ssh -- docker images --format '{{.Repository}}:{{.Tag}}' | tr -d '\r' | sort -u))
    [ -z "${missing}" ] || die "Images missing from minikube, run the build step: $(echo ${missing})"
  fi
  ok "Chart $(sed -n 's/^version: *//p' "${CHART_DIR}/Chart.yaml") ready, $(grep -c '^kind:' "${WORK_DIR}/manifests.yaml") manifests rendered (${WORK_DIR}/manifests.yaml)"
}

function print_progress {
  local pods total ready bad
  pods=$(kc -n "${NAMESPACE}" get pods --no-headers 2> /dev/null || true)
  total=$(grep -c . <<< "${pods}" || true)
  ready=$(awk '{ split($2, r, "/"); if ($3 == "Completed" || (r[1] == r[2] && $3 == "Running")) n++ } END { print n + 0 }' <<< "${pods}")
  bad=$(awk '$3 ~ /BackOff|Err|Error|Invalid|OOMKilled/ { printf "%s(%s) ", $1, $3 }' <<< "${pods}")
  echo "    $(date +%H:%M:%S) pods ready: ${ready}/${total}${bad:+  ${C_YELLOW}failing: ${bad}${C_RESET}}"
}

function diagnose {
  warn "Deployment diagnostics"
  hm -n "${NAMESPACE}" status "${RELEASE}" 2> /dev/null | head -n 20 || true
  kc -n "${NAMESPACE}" get pods -o wide || true
  local job pod
  for job in $(kc -n "${NAMESPACE}" get jobs -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{"\n"}{end}' 2> /dev/null); do
    warn "Logs of the failed job ${job}"
    kc -n "${NAMESPACE}" logs "job/${job}" --tail=60 --all-containers 2> /dev/null || true
  done
  for pod in $(kc -n "${NAMESPACE}" get pods --no-headers 2> /dev/null | awk '$3 ~ /BackOff|Error/ { print $1 }'); do
    warn "Logs of ${pod}"
    kc -n "${NAMESPACE}" logs "${pod}" --tail=40 --all-containers 2> /dev/null || true
  done
  warn "Last warning events"
  kc -n "${NAMESPACE}" get events --field-selector type=Warning --sort-by=.lastTimestamp 2> /dev/null | tail -n 20 || true
}

# wait_rollouts TIMEOUT: waits for every Deployment and StatefulSet of the namespace to be
# rolled out, with a progress line. Returns 1 when one is not ready within TIMEOUT.
function wait_rollouts {
  local timeout=$1 pid
  (
    for workload in $(kc -n "${NAMESPACE}" get deploy,statefulset -o name); do
      kc -n "${NAMESPACE}" rollout status "${workload}" --timeout="${timeout}" > /dev/null || exit 1
    done
  ) &
  pid=$!
  trap 'kill ${pid} 2> /dev/null' INT TERM
  while kill -0 "${pid}" 2> /dev/null; do
    sleep 20
    kill -0 "${pid}" 2> /dev/null && print_progress
  done
  trap - INT TERM
  wait "${pid}"
}

# helm_deploy "label": helm upgrade --install, then waits for the workloads.
# No --wait: Helm would then wait for Keycloak and report-api before running the post-install
# configurator, the very job that creates their databases. Helm still waits for its hook Jobs.
function helm_deploy {
  local values_args=(-f "${SECRETS_FILE}" -f "${VALUES_FILE}") f log pid
  for f in "${EXTRA_VALUES[@]}"; do values_args+=(-f "${f}"); done
  log="${WORK_DIR}/helm-$(date +%Y%m%d-%H%M%S).log"

  info "helm upgrade --install ${RELEASE}, hook jobs included (timeout ${HELM_TIMEOUT}, log: ${log})"
  hm upgrade --install "${RELEASE}" "${CHART_DIR}" \
    --namespace "${NAMESPACE}" --create-namespace \
    "${values_args[@]}" \
    --timeout "${HELM_TIMEOUT}" > "${log}" 2>&1 &
  pid=$!
  trap 'kill ${pid} 2> /dev/null' INT TERM
  while kill -0 "${pid}" 2> /dev/null; do
    sleep 20
    kill -0 "${pid}" 2> /dev/null && print_progress
  done
  trap - INT TERM
  if ! wait "${pid}"; then
    tail -n 30 "${log}" >&2
    diagnose
    die "$1 failed"
  fi

  info "Waiting for the Deployments and StatefulSets to be rolled out"
  if ! wait_rollouts 15m; then
    diagnose
    die "$1 failed: workloads not ready"
  fi
  ok "$1 succeeded (revision $(hm -n "${NAMESPACE}" history "${RELEASE}" --max 1 -o json | sed -n 's/.*"revision":\([0-9]*\).*/\1/p'))"
}

function deploy {
  if hm -n "${NAMESPACE}" status "${RELEASE}" > /dev/null 2>&1; then
    step "Upgrade the existing release ${RELEASE} in ${NAMESPACE}" || return 0
  else
    step "Install the release ${RELEASE} in ${NAMESPACE} (setup jobs included, can take 15+ minutes)" || return 0
  fi
  helm_deploy "Deployment"
}

function upgrade_test {
  is_yes "${UPGRADE_TEST}" || return 0
  step "Upgrade test: helm upgrade with the same values (migration and configurator jobs)" || return 0
  helm_deploy "Upgrade"
  run_checks
}

# Hosts of the deployed ingresses, or of the rendered manifests before any deployment.
function ingress_hosts {
  local hosts
  hosts=$(kc get ingress -A -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' 2> /dev/null || true)
  if [ -z "${hosts}" ] && [ -f "${WORK_DIR}/manifests.yaml" ]; then
    hosts=$(sed -n 's/^ *- host: *"\{0,1\}\([^" ]*\)"\{0,1\} *$/\1/p' "${WORK_DIR}/manifests.yaml")
  fi
  grep -F ".${DOMAIN}" <<< "${hosts}" | sort -u || true
}

# The block between "# <domain>" and "# </domain>" is replaced, the same markers as the
# append-etc-hosts.sh script of the Phrasea repository.
function edit_hosts {
  is_yes "${EDIT_HOSTS}" || return 0
  local ip hosts start end block current
  ip=$(minikube -p "${PROFILE}" ip)
  step "Point the domains of ${DOMAIN} to ${ip} in /etc/hosts (sudo)" || return 0

  hosts=$(ingress_hosts)
  [ -n "${hosts}" ] || { warn "No ingress host found for ${DOMAIN}, /etc/hosts left as is"; return 0; }
  start="# <${DOMAIN}>"
  end="# </${DOMAIN}>"
  block=$(echo "${start}"; awk -v ip="${ip}" '{ print ip, $0 }' <<< "${hosts}"; echo "${end}")
  current=$(START="${start}" END="${end}" awk '
    $0 == ENVIRON["START"] { found = 1 }
    found { print }
    $0 == ENVIRON["END"] { found = 0 }
  ' /etc/hosts)

  if [ "${current}" = "${block}" ]; then
    ok "/etc/hosts already up to date"
    return 0
  fi
  if [ -n "${current}" ] && ! grep -qxF "${end}" /etc/hosts; then
    die "/etc/hosts has \"${start}\" without \"${end}\", fix it by hand"
  fi

  if [ -n "${current}" ]; then
    START="${start}" END="${end}" BLOCK="${block}" awk '
      $0 == ENVIRON["START"] { if (!done) print ENVIRON["BLOCK"]; done = 1; skip = 1; next }
      skip { if ($0 == ENVIRON["END"]) skip = 0; next }
      { print }
    ' /etc/hosts > "${WORK_DIR}/hosts"
  else
    { cat /etc/hosts; echo "${block}"; } > "${WORK_DIR}/hosts"
  fi
  diff /etc/hosts "${WORK_DIR}/hosts" || true
  cat "${WORK_DIR}/hosts" | sudo tee /etc/hosts > /dev/null
  rm -f "${WORK_DIR}/hosts"
  ok "/etc/hosts updated ($(wc -l <<< "${hosts}") domains)"
}

CHECKS_FAILED=0
CHECKS_PASSED=0
CHECKS_WARNED=0
function pass { CHECKS_PASSED=$((CHECKS_PASSED + 1)); ok "$*"; }
function fail { CHECKS_FAILED=$((CHECKS_FAILED + 1)); echo "${C_RED}[✗]${C_RESET} $*"; }
function soft_fail { CHECKS_WARNED=$((CHECKS_WARNED + 1)); warn "$*"; }

# check_http "label" URL "accepted codes" [curl args…]: requests the URL through the ingress
# from the host, without relying on /etc/hosts.
function check_http {
  local label=$1 url=$2 accepted=$3 host code body
  shift 3
  host=$(sed -E 's#^https?://([^/:]+).*#\1#' <<< "${url}")
  body=$(mktemp)
  for _ in 1 2 3 4 5 6; do
    code=$(curl -sk -o "${body}" -w '%{http_code}' --max-time 30 \
      --resolve "${host}:443:${MINIKUBE_IP}" "$@" "${url}" || true)
    [[ " ${accepted} " == *" ${code} "* ]] && break
    sleep 10
  done
  if [[ " ${accepted} " == *" ${code} "* ]]; then
    pass "${label}: ${code} ${url}"
  else
    fail "${label}: got ${code}, expected ${accepted} — ${url}"
    head -c 300 "${body}" | sed 's/^/      /'; echo
  fi
  rm -f "${body}"
}

function json_field { sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p"; }

# secret_value parent key: value of the first "key:" following the "parent:" line of the secrets file.
function secret_value {
  awk -v p="$1:" -v k="$2:" '
    $1 == p { found = 1; next }
    found && $1 == k { sub(/^[^:]*: */, ""); gsub(/"/, ""); print; exit }
  ' "${SECRETS_FILE}" 2> /dev/null || true
}

function run_checks {
  title "Checks"
  CHECKS_FAILED=0; CHECKS_PASSED=0; CHECKS_WARNED=0
  MINIKUBE_IP=$(minikube -p "${PROFILE}" ip)

  if hm -n "${NAMESPACE}" status "${RELEASE}" 2> /dev/null | grep -q '^STATUS: deployed'; then
    pass "Helm release ${RELEASE} deployed"
  else
    fail "Helm release ${RELEASE} is not in the deployed state"
  fi

  if kc -n "${NAMESPACE}" wait --for=condition=Available deploy --all --timeout=600s > /dev/null 2>&1; then
    pass "Every Deployment is available ($(kc -n "${NAMESPACE}" get deploy --no-headers | wc -l))"
  else
    fail "Deployments not available: $(kc -n "${NAMESPACE}" get deploy --no-headers | awk '{ split($2, r, "/"); if (r[1] != r[2]) printf "%s ", $1 }')"
  fi

  local sts
  for sts in $(kc -n "${NAMESPACE}" get statefulsets -o name); do
    if kc -n "${NAMESPACE}" rollout status "${sts}" --timeout=300s > /dev/null 2>&1; then
      pass "${sts#*/} ready"
    else
      fail "${sts#*/} not ready"
    fi
  done

  local restarting
  restarting=$(kc -n "${NAMESPACE}" get pods --no-headers | awk '$4 + 0 > 3 { printf "%s(%s) ", $1, $4 }')
  [ -z "${restarting}" ] || soft_fail "Pods restarted more than 3 times: ${restarting}"

  local d=${DOMAIN}
  check_http "Keycloak realm" "https://keycloak.${d}/realms/phrasea/.well-known/openid-configuration" "200"
  check_http "Databox API" "https://api-databox.${d}/" "200 401" -H 'Accept: application/ld+json'
  check_http "Expose API" "https://api-expose.${d}/" "200 401" -H 'Accept: application/ld+json'
  check_http "Uploader API" "https://api-uploader.${d}/" "200 401" -H 'Accept: application/ld+json'
  check_http "Databox client" "https://databox.${d}/" "200 302 303 307 308"
  check_http "Expose client" "https://expose.${d}/" "200 302 303 307 308"
  check_http "Uploader client" "https://uploader.${d}/" "200 302 303 307 308"
  check_http "Dashboard" "https://dashboard.${d}/" "200 302 303 307 308"
  check_http "MinIO" "https://minio.${d}/minio/health/live" "200"
  check_http "MinIO console" "https://minio-console.${d}/" "200"
  check_http "Sockudo (websocket)" "https://ws.${d}/up/phrasea" "200"
  if kc -n "${NAMESPACE}" get ingress -o name 2> /dev/null | grep -q mailpit; then
    check_http "Mailpit" "https://mailpit.${d}/" "200 401"
  fi

  local code
  code=$(kc -n "${NAMESPACE}" run "smoke-dns-$$" --rm -i --quiet --restart=Never --pod-running-timeout=5m \
    --image="${CURL_IMAGE}" --command -- \
    curl -sk -o /dev/null -w '%{http_code}' --max-time 30 \
    "https://keycloak.${d}/realms/phrasea/.well-known/openid-configuration" 2> /dev/null | tail -c 3 || true)
  if [ "${code}" = 200 ]; then
    pass "Public URLs reachable from the pods (CoreDNS → ingress)"
  else
    fail "Public URLs not reachable from the pods (got '${code}'): check the CoreDNS step"
  fi

  [ -f "${SECRETS_FILE}" ] || { soft_fail "No ${SECRETS_FILE}: Keycloak and API checks skipped"; checks_summary; return; }

  local kc_url="https://keycloak.${d}" resolve=(--resolve "keycloak.${d}:443:${MINIKUBE_IP}") token
  token=$(curl -sk "${resolve[@]}" --max-time 30 "${kc_url}/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli -d username=admin \
    --data-urlencode "password=$(secret_value masterAdmin password)" | json_field access_token || true)
  if [ -z "${token}" ]; then
    fail "Keycloak master admin login refused"
  else
    pass "Keycloak master admin login"
    local client
    for client in databox-app expose-app uploader-app; do
      if curl -sk "${resolve[@]}" --max-time 30 -H "Authorization: Bearer ${token}" \
        "${kc_url}/admin/realms/phrasea/clients?clientId=${client}" | grep -q '"clientId"'; then
        pass "Keycloak client ${client} provisioned by the configurator"
      else
        soft_fail "Keycloak client ${client} not found in the phrasea realm"
      fi
    done
    if curl -sk "${resolve[@]}" --max-time 30 -H "Authorization: Bearer ${token}" \
      "${kc_url}/admin/realms/phrasea/users?username=admin&exact=true" | grep -q '"username"'; then
      pass "Default admin user present in the phrasea realm"
    else
      fail "Default admin user missing from the phrasea realm"
    fi
  fi

  local admin_password user_token
  admin_password=$(secret_value defaultAdmin password)
  user_token=$(curl -sk "${resolve[@]}" --max-time 30 "${kc_url}/realms/phrasea/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli -d username=admin \
    --data-urlencode "password=${admin_password}" | json_field access_token || true)
  if [ -z "${user_token}" ]; then
    soft_fail "Could not log in as the default admin (password grant), authenticated API call skipped"
  else
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 \
      --resolve "api-databox.${d}:443:${MINIKUBE_IP}" -H 'Accept: application/json' \
      -H "Authorization: Bearer ${user_token}" "https://api-databox.${d}/workspaces" || true)
    case "${code}" in
      200) pass "Databox API, authenticated as the default admin: 200" ;;
      401|403) soft_fail "Databox API refused the admin-cli token (${code}): audience not accepted, not a deployment failure" ;;
      *) fail "Databox API, authenticated: got ${code}" ;;
    esac
  fi

  checks_summary
}

function checks_summary {
  echo
  echo "${C_BOLD}Checks:${C_RESET} ${C_GREEN}${CHECKS_PASSED} passed${C_RESET}, ${C_YELLOW}${CHECKS_WARNED} warnings${C_RESET}, ${C_RED}${CHECKS_FAILED} failed${C_RESET}"
  if [ "${CHECKS_FAILED}" -gt 0 ]; then
    diagnose
    return 1
  fi
}

function print_access {
  local admin_password mailpit_auth
  admin_password=$(secret_value defaultAdmin password)
  mailpit_auth=$(secret_value mailpit auth)
  title "Access"
  cat <<EOF
  Dashboard        https://dashboard.${DOMAIN}
  Databox          https://databox.${DOMAIN}
  Expose           https://expose.${DOMAIN}
  Uploader         https://uploader.${DOMAIN}
  Keycloak         https://keycloak.${DOMAIN}  (master admin: admin / $(secret_value masterAdmin password))
  Phrasea admin    admin / ${admin_password}
  MinIO console    https://minio-console.${DOMAIN}  (access/secret keys in the secrets file)
$(is_yes "${MAILPIT}" && echo "  Mailpit          https://mailpit.${DOMAIN}  (${mailpit_auth})")

  Values           ${VALUES_FILE}
  Secrets          ${SECRETS_FILE}
  kubectl          kubectl --context ${PROFILE} -n ${NAMESPACE} get pods
  Re-run checks    $0 test
  Uninstall        $0 down
EOF
}

function cmd_up {
  require_tools minikube kubectl helm curl openssl awk sed
  configure
  start_minikube
  install_ingress
  configure_cluster_dns
  create_certificate
  build_local_images
  write_values
  prepare_chart
  deploy
  edit_hosts
  local status=0
  if step "Run the checks"; then
    run_checks || status=$?
    if [ "${status}" = 0 ]; then
      upgrade_test || status=$?
    fi
  fi
  print_access
  return "${status}"
}

function cmd_test {
  require_tools minikube kubectl helm curl
  set_work_dir
  if [ -z "${PHRASEA_MINIKUBE_DOMAIN:-}" ] && [ -f "${VALUES_FILE}" ]; then
    DOMAIN=$(sed -n 's/^  domain: "\(.*\)"$/\1/p' "${VALUES_FILE}")
  fi
  run_checks
}

function cmd_status {
  require_tools minikube kubectl helm
  hm -n "${NAMESPACE}" status "${RELEASE}" | head -n 8
  kc -n "${NAMESPACE}" get pods,ingress
}

function cmd_down {
  require_tools kubectl helm
  title "Uninstall ${RELEASE} from ${PROFILE}/${NAMESPACE}"
  confirm "Delete the release and the namespace ${NAMESPACE} with all its data?" || exit 0
  hm -n "${NAMESPACE}" uninstall "${RELEASE}" --wait --timeout 10m || true
  kc delete namespace "${NAMESPACE}" --wait=true --ignore-not-found
  ok "Release and namespace deleted (the secrets file is kept, delete it to start from scratch)"
}

function cmd_destroy {
  require_tools minikube
  set_work_dir
  title "Delete the minikube profile ${PROFILE}"
  confirm "Delete the minikube profile ${PROFILE} and every volume in it?" || exit 0
  minikube delete -p "${PROFILE}"
  if [ -d "${WORK_DIR}" ] && confirm "Also delete ${WORK_DIR} (generated secrets, certificate, chart copy)?"; then
    rm -rf "${WORK_DIR}"
  fi
  ok "Done"
}

"cmd_${COMMAND}"
