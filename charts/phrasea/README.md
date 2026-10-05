# Phrasea Chart

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

## Upgrade notes

### Chart 3.0

The defaults now target the Phrasea images released after 4.4.2. To deploy 4.4.x images, set:

```yaml
databox:
  client:
    port: 80          # 4.4.x databox client is served by nginx
soketi:
  serverSide:
    internal: false   # 4.4.x PHP services cannot reach Soketi over plain HTTP
```

Other behaviour changes:

- `keycloak.realm.loginRegistrationAllowed` now defaults to `false`.
- The Soketi ingress is enabled by default (realtime notifications).
- `databox.api.config.secrets.secretKey` is stored in the `databox-worker-secrets` Secret.
- `elasticsearch.url` now defaults to the subchart service in `values.yaml`: remove an empty `elasticsearch.url:` from your values.
- Defaults now live in `values.yaml` only, templates no longer fall back on them. An empty key in your values
  (e.g. `region:` copied from the 2.x `values.yaml`) overrides the default: remove it or set a value.
  The S3/CloudFront regions are required and fail the rendering when empty.
- `stack.runSynchronize` is removed: the configuration is synchronized by the configurator migration job
  (`stack.runMigrations`).

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
