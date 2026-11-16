# Phrasea Chart

## Databox Mapbox configuration

To enable maps in the Databox client, configure a public Mapbox access token:

```yaml
databox:
  client:
    mapbox:
      token: "pk.REPLACE_WITH_YOUR_PUBLIC_TOKEN"
```

The chart injects this value as `MAPBOX_TOKEN` into the Databox client
container. The client exposes it to the browser at runtime; use a public
`pk.*` token, never a secret `sk.*` token, and restrict its allowed URLs to
your Databox client domains.

The default empty value disables maps. This setting is independent from
`expose.client.mapbox.token`. After updating the token with `helm upgrade`,
recreate the Databox client pods to load the new environment variable.
No image rebuild is needed.

### Ingress controller

Since chart 3.0.0, every Ingress uses the `traefik` IngressClass by default
(ingress-nginx is retired upstream). To keep ingress-nginx, set:

```yaml
ingress:
  className: nginx
```

An empty `className` omits `spec.ingressClassName`, so the cluster default
IngressClass applies.

`ingress.annotations` is added to every Ingress of the chart; the annotations
of each Ingress take precedence. For instance, to attach a Traefik Middleware
to the whole stack:

```yaml
ingress:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: my-namespace-my-middleware@kubernetescrd
```

With Traefik, the `nginx.ingress.kubernetes.io/*` annotations of the default
values are ignored: request body size and timeouts are set on the Traefik
entrypoints (`transport.respondingTimeouts`). The Sockudo internal paths
(`/usage`, `/stats`, `/operator`) are denied with a Traefik `Middleware`
(`traefik.io/v1alpha1` CRDs required) instead of the ingress-nginx denylist
annotation.

### TLS

You can enable wildcard TLS:

```yaml
ingress:
  tls:
    wildcard:
      enabled: true
      #externalSecretName:
      # or
      crt: |
        ...
      key: |
        ...
```

or configure TLS for each ingress:
```yaml
uploader:
  api:
    ingress:
      tls:
      - secretName: uploader-api-tls-secret
        # Optional:
        # if not provided the hostname will be automatically set
        # with the .Values.uploader.api.hostname value
        host: api.uploader.com
  client:
    ingress:
      tls:
      - secretName: uploader-client-tls-secret
        # Optional:
        # if not provided the hostname will be automatically set
        # with the .Values.uploader.client.hostname value
        host: client.uploader.com
```

## [Optional] Install cert-manager

We need to replicate tls secret across namespaces, so they can be used in all ingresses.

```bash
helm repo add emberstack https://emberstack.github.io/helm-charts
helm repo update
helm upgrade --install reflector emberstack/reflector
```

Follow: https://cert-manager.io/docs/installation/helm/

Install Gandi webhook:

```bash
helm upgrade --install webhook-gandi cert-manager-webhook-gandi \
    --repo https://bwolf.github.io/cert-manager-webhook-gandi \
    --namespace cert-manager \
    --set features.apiPriorityAndFairness=true \
    --set image.repository=barsanet/cert-manager-webhook-gandi \
    --set image.tag=0.2.0-go1.20 \
    --set logLevel=6
```

Check the logs

```bash
kubectl get pods -n cert-manager --watch
kubectl logs -n cert-manager cert-manager-webhook-gandi-XYZ
```

## Shutdown stack (while keeping data)

Change the:

```yaml
stack:
  running: false
```

Restore stack:

If your PostgreSQL service is enabled, you will need to disable migrations for the pod to start.

Change the:

```yaml
stack:
    running: true
    runMigrations: false
```

Now `helm upgrade`!

In a second phase, you must re-enable migrations:


```yaml
stack:
    running: true
    runMigrations: true
```

`helm upgrade` again!

## Similarity search and face recognition

The Databox "Similarity" and "Face Recognition" integrations rely on two self-hosted services, disabled by default.

```yaml
similarityEmbedder:
  enabled: true

faceRecognition:
  enabled: true
```

The Databox API and worker then reach them through `similarityEmbedder.url` / `faceRecognition.url`.
The similarity search (kNN on dense vectors) requires Elasticsearch >= 8.12.
Backfill the existing assets with `bin/console app:similarity:index` and `bin/console app:face-recognition:index`
from the interactive pod or a worker pod.

## Upgrade notes

### Chart 3.0

The defaults now target the Phrasea 5.0 images. The 4.4.x images are no longer supported: they still need the former
databox CronJobs, Zippy, Soketi and Elasticsearch 7, removed below.

Other behaviour changes:

- `keycloak.realm.loginRegistrationAllowed` now defaults to `false`.
- The Sockudo ingress is enabled by default (realtime notifications).
- `databox.api.config.secrets.secretKey` is stored in the `databox-worker-secrets` Secret.
- `elasticsearch.url` now defaults to the subchart service in `values.yaml`: remove an empty `elasticsearch.url:` from your values.
- Defaults now live in `values.yaml` only, templates no longer fall back on them. An empty key in your values
  (e.g. `region:` copied from the 2.x `values.yaml`) overrides the default: remove it or set a value.
  The S3/CloudFront regions are required and fail the rendering when empty.
- `stack.runSynchronize` is removed: the configuration is synchronized by the configurator migration job
  (`stack.runMigrations`).
- Keycloak and the report API are no longer built with the Phrasea images: they come from
  `keycloak.image` and `report.image` (public ECR by default) instead of `repository.baseUrl` / `repository.tag`.
- The databox `daily` and `hourly` CronJobs (`databox.cronJob`) are replaced by Symfony Scheduler: the
  `databox-scheduler`, `expose-scheduler` and `uploader-scheduler` StatefulSets (`databox.scheduler`,
  `expose.scheduler`, `uploader.scheduler`) run the worker image with `WORKER_PRIORITIES=scheduler_main`, always with a
  single pod. Without `databox-scheduler`, the scheduled automations never run. Remove `databox.cronJob` from your
  values. `stack.schedulerOffset` shifts every periodic task by this number of seconds, so that stacks sharing the same
  resources do not run them at the same time.
- Zippy is removed: Expose and Databox build their ZIP archives themselves. Remove the `zippy`, `databox.zippy` and
  `expose.zippy` keys from your values, and the `zippy.<domain>` DNS entry.
- The Databox, Expose, Uploader and dashboard clients are Next.js servers listening on port 3000: the former nginx
  client images (listening on port 80) are no longer supported. `databox.client.port` is removed. The headers formerly
  set by their nginx (HSTS, `X-Robots-Tag`, `X-Content-Type-Options`) are no longer emitted: set them on the ingress.
- The clients send a Content Security Policy restricting the scripts to the nonce of each response, only reported
  (`Content-Security-Policy-Report-Only`) while `security.csp.reportOnly` is true, the default. Before enforcing it,
  list in `security.csp.extraSources` any host serving files to the pages outside the stack (CDN other than the
  CloudFront URLs, external logo…). The violations and the browser errors reach Sentry through the `/api/relay` route of
  the clients, rate limited by `sentry.frontend.tunnelRateLimitPerIp` and `sentry.frontend.tunnelRateLimitGlobal`.
- `matomo.disableCookies` now applies to every client, not only Databox.
- `expose.api.subnet` is removed: the Expose API nginx no longer reads `PS_SUBNET` (`/purge` only refuses the requests
  relayed by a proxy).

### APP_SECRET

The Databox, Expose and Uploader APIs now get their Symfony `APP_SECRET` from the `<app>-app-secret` Secret, created
from `databox.appSecret.value`, `expose.appSecret.value` and `uploader.appSecret.value` (required for each enabled app),
or taken from the existing Secret named by `<app>.appSecret.externalSecretName` (key `APP_SECRET`).

Until now, the `APP_SECRET` committed in each `*/api/.env` (shipped in the images, hence public) signed the URI JWTs
(asset downloads, publication archives, Phraseanet tokens). Set a distinct random value per app and per instance, e.g.
`openssl rand -hex 32`: the URLs signed with the former value stop working once the new pods are running.

### Allowed file types and upload limits

`databox.allowedFileTypes`, `uploader.allowedFileTypes` and the new `expose.allowedFileTypes` (`ALLOWED_FILE_TYPES`)
keep their `type(.ext1,.ext2),…` format, but each entry is now a couple: an upload is accepted when one entry matches
its MIME type **and** lists its extension, and the content of the file must match its declared type. A main type
wildcard (`*/*`) fails every upload. The default lists are rewritten accordingly (`.indd` under `application/*`,
`.txt`, `.md`, `.csv` under `text/*`, `.m4a` and `.mp2` under `audio/*`…): rewrite the lists of your values the same
way. `expose.allowedFileTypes` must cover what Databox publishes: its types plus the output formats of the renditions.

Other storage defaults:

- `<app>.s3MaxObjectSize` defaults to 5 TiB, the largest object S3 accepts (formerly 48.8 TiB).
- `databox.maxUploadFileSize` and `expose.maxUploadFileSize` (100 GiB by default) bound the size of an uploaded file;
  the uploader reads it from the stack configuration (`uploader.max_upload_file_size` in `globalConfig.content`).
  Raise them before upgrading if larger files are sent.
- `<app>.multipartUploadRateLimit` (60 upload requests per minute and per user) and `<app>.multipartUploadMaxPending`
  (20 uploads in progress per user) answer `429` beyond.
- `databox.api.config.cloudFront.ttl` and `expose.api.config.cloudFront.ttl` default to 3600 seconds (formerly 86400):
  a signed URL stays valid for its whole TTL, even once its user has lost access to the file.

### Soketi → Sockudo

Soketi is no longer maintained: the WebSocket server is now [Sockudo](https://github.com/sockudo/sockudo)
(`ghcr.io/sockudo/sockudo`), which speaks the same Pusher protocol. Everything named after Soketi is renamed, with no
fallback on the old names:

- the `soketi` values become `sockudo` (`sockudo.host`, `sockudo.appId`, `sockudo.key`, `sockudo.secret`,
  `sockudo.serverSide.*`, `sockudo.ingress.*`...). `soketi.app.mode` and `soketi.app.command` are removed.
- the public host defaults to `ws.<domain>`: update your DNS and TLS certificates, or set `sockudo.host` to the
  former `soketi.<domain>`.
- the `soketi` ConfigMap, Secret and Service become `sockudo`, and the `SOKETI_*` variables `SOCKUDO_*`.
- `sockudo.externalSecretName` names an existing Secret holding `SOCKUDO_SECRET`.

`sockudo.appId`, `sockudo.key` and `sockudo.secret` must all be set: otherwise Sockudo keeps the demo app of its
bundled configuration. Sockudo serves `/usage` and `/stats` on the app port: the `sockudo-internal-paths` Ingress denies
them (and `/operator`) on the public host.

### Elasticsearch 7.17 → 9

The bundled Elasticsearch is now 9.1.4, run by the last release of the Elastic subchart (8.5.1), with its security
enabled (see [Elasticsearch authentication](#elasticsearch-authentication)).

Elasticsearch 9 cannot start on the data of a 7.x node: the default `elasticsearch.clusterName` becomes
`elasticsearch9-databox`, so that the new StatefulSet starts on a new PVC. The former StatefulSet is removed by the
upgrade and its PVC (`elasticsearch-databox-master-elasticsearch-databox-master-0`) is kept: delete it once the new
cluster is populated. If you set `elasticsearch.clusterName` in your values, change it as well (or delete the PVC).

Rebuild the indexes after the upgrade, from the interactive pod or a databox worker pod:

```bash
bin/console fos:elastica:populate
```

An external Elasticsearch (`elasticsearch.enabled: false`) must be upgraded to 9.x as well (8.12 at least for the
similarity search).

A stack already running a 5.0 pre-release must rebuild the `asset` index as well: its new `attributeValues` field
applies the asset rights of `GET /attributes?definition=`, which returns no value until the index is repopulated.

```bash
bin/console fos:elastica:populate --index=asset
```

### Elasticsearch authentication

The asset rights are applied inside Elasticsearch: anyone reaching the cluster could read every workspace. The bundled
Elasticsearch now runs with its security enabled, without TLS (plain HTTP inside the cluster), as in the docker compose
stack:

- `elasticsearch.secret.password` is the password of the `elastic` superuser, only used by the readiness probe and the
  new `elasticsearch-setup` Job. Set it: left empty, the subchart would generate a new one at each upgrade.
- `elasticsearch-setup` (post-install and post-upgrade hook) creates or updates the user of the applications,
  `elasticsearch.username` (`databox` by default) with `elasticsearch.password`, and its role: every privilege on the
  indices starting with `elasticsearch.indexPrefix` (every index when it is empty), `monitor` on the cluster.
- The Databox API, workers, scheduler and Jobs get `ELASTICSEARCH_USERNAME` and `ELASTICSEARCH_PASSWORD` from the
  `databox-elasticsearch` Secret, or from the existing Secret named by `elasticsearch.externalSecretName`.
- Without transport TLS, Elasticsearch only starts with the single-node discovery (`discovery.type: single-node`, and
  `elasticsearch.roles: []` so that the subchart sets no `cluster.initial_master_nodes`): keep `elasticsearch.replicas`
  to 1.

The indices of an existing volume are kept: enabling the security of an existing node is supported. Until the
`elasticsearch-setup` Job has run at the end of the upgrade, the Databox API and workers get a 401 from Elasticsearch.
The `elastic` password is only read from `elasticsearch.secret.password` as long as it has not been changed through the
API (`_security/user/elastic/_password`).

With an external cluster (`elasticsearch.enabled: false`), nothing is created: set `elasticsearch.username` and
`elasticsearch.password` to an existing user, or empty both for a cluster without authentication.

### RabbitMQ 3.7 → 3.13

The default `rabbitmq.image` is now `rabbitmq:3.13.7-management`. RabbitMQ cannot start a 3.13 node
on data written by 3.7: an existing stack must either keep its current image or upgrade step by step.

To keep the previous version:

```yaml
rabbitmq:
  image: rabbitmq:3.7.14-management
```

To upgrade, run one `helm upgrade` per version below, enabling all the feature flags before moving to the next one:

```bash
# for each image: 3.8.35, 3.9.29, 3.10.25, 3.11.28, 3.12.14, 3.13.7 (all "-management")
helm upgrade ... --set rabbitmq.image=rabbitmq:3.8.35-management
kubectl rollout status deploy/rabbitmq
kubectl exec deploy/rabbitmq -- rabbitmqctl enable_feature_flag all
```

Alternatively, once every queue is drained (workers scaled down), the RabbitMQ PVC can be deleted;
the configurator must then be run again to recreate the vhosts (`configurator.configure.rabbitmq`).
