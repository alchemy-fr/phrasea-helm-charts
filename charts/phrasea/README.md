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

## Run migration

```bash
export MIGRATION_NAME=20230807
helm template <release-name> -f values.yaml \
  --set "configurator.executeMigration" "${MIGRATION_NAME}" \
    -s templates/job-tests.yaml | kubectl apply -f -
kubectl attach -it pod/${MIGRATION_NAME}
kubectl delete -it pod/${MIGRATION_NAME}
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
