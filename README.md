# Phrasea Helm Charts

Welcome to the official Helm Charts for Phrasea DAM products made by Alchemy.
This repository contains all the necessary resources to deploy and manage our DAM applications in Kubernetes environments.

## Products

### Phrasea
Phrasea is the modern descendant of Phraseanet, representing a complete rewrite of the original solution. Designed for modern infrastructures and streamlined operations, Phrasea offers enhanced performance and simplified management. The Helm chart for Phrasea facilitates its seamless integration and management within a Kubernetes environment, leveraging the latest advancements in technology and design.

- **Source**: [Phrasea on GitHub](https://github.com/alchemy-fr/phrasea)
- **Old Helm Deployment**: [Old Phrasea Helm Releases](https://github.com/alchemy-fr/alchemy-helm-charts-repo/releases?q=phrasea-&expanded=true)


## Configuration

Each chart includes a `values.yaml` file, which you can customize according to your needs. For detailed configuration options, it is recommended to review the specific documentation of each chart.

# Test chart syntax

Run the following command to test the chart locally with Helm:

```bash
cd charts/phrasea
helm dependency build
helm template --debug my-phrasea-release --values=.dummy.values.yaml .
```

# Test a full deployment on minikube

`bin/minikube-test-deploy.sh` deploys the chart on a local minikube cluster, then checks the
deployment:

```bash
bin/minikube-test-deploy.sh            # asks every setting, then confirms each step
bin/minikube-test-deploy.sh --yes      # same, with the defaults / env values, no question
bin/minikube-test-deploy.sh test       # only the checks, against the deployed stack
bin/minikube-test-deploy.sh down       # uninstall the release and delete its namespace
bin/minikube-test-deploy.sh destroy    # delete the minikube profile
```

Requirements on the host: `minikube`, `kubectl`, `helm`, `curl`, `openssl`, and `mkcert` for a
certificate trusted by the browser (otherwise a self-signed one is created). Building the images
locally (the default) also needs a [Phrasea](https://github.com/alchemy-fr/phrasea) checkout,
`../phrasea` by default.

Steps:

1. **Settings**: minikube profile, CPUs, memory, disk (a bare number is read as gigabytes),
   domain (`phrasea.minikube`), namespace, chart, ingress controller, images… Every setting also
   has an environment variable (`--help` lists them).
2. **minikube**: starts the profile (an existing one keeps its CPU/memory settings).
3. **Ingress controller**: Traefik installed with its Helm chart (the default IngressClass of the
   chart 3.x) or the minikube `ingress` addon (ingress-nginx). Both listen on ports 80/443 of the
   minikube IP.
4. **Cluster DNS**: CoreDNS answers the ingress controller IP for `*.<domain>`, so that the pods
   reach the public URLs (Keycloak, MinIO…) as a browser does.
5. **TLS**: a wildcard certificate `*.<domain>` (mkcert), given to the chart as
   `ingress.tls.wildcard`.
6. **Images**: builds the images in the minikube Docker daemon from the Phrasea checkout
   (`alchemyfr/ps-*:minikube`), or pulls the published ones (`registry`).
7. **Values**: `secrets.yaml` (passwords and keys generated once, kept for the next upgrades) and
   `values.yaml` (regenerated at each run) in `~/.local/state/phrasea-minikube/<profile>/`.
   Extra values files are passed with `-f FILE`.
8. **Chart**: copies the chart (`charts/phrasea`, or a released version), drops the private
   `phrasea-parade` dependency when it is not vendored, then runs `helm lint` and `helm template`.
9. **Deployment**: `helm upgrade --install --wait --wait-for-jobs`, with the pods status every
   20 seconds and the logs of the failed jobs/pods on failure.
10. **/etc/hosts** (sudo): points the hosts of the ingresses to the minikube IP.
11. **Checks**: release deployed, Deployments and StatefulSets ready, every ingress answering
    (Keycloak realm, APIs, clients, MinIO, Sockudo, Mailpit), public URLs reachable from a pod,
    Keycloak master admin login, configurator clients and default admin user present, an
    authenticated Databox API call.
12. **Upgrade test** (optional): a second `helm upgrade` with the same values, which runs the
    migration and configurator jobs, then the checks again.

The checks reach the ingress with `curl --resolve`: they do not depend on `/etc/hosts`.

To test a fresh image without redeploying, build it with the minikube Docker daemon from the
Phrasea checkout, then restart its pods:

```bash
eval $(minikube -p phrasea docker-env)
REGISTRY_NAMESPACE=alchemyfr/ps- DOCKER_TAG=minikube COMPOSE_FILE=docker-compose.yml docker compose build databox-api-php
kubectl --context phrasea -n phrasea rollout restart deploy/databox-api-php
```
