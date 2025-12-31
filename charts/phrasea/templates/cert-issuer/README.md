# TLS Certificate Management with cert-manager and Let's Encrypt

Automatic TLS certificate management using cert-manager with Let's Encrypt DNS-01 challenges.

## Prerequisites

- **NGINX Ingress Controller** installed and configured with LoadBalancer service
- **cert-manager v1.13+** installed in the cluster
- **DNS webhook** installed for your provider (Scaleway, Gandi, or Route53)
- DNS properly configured to point to your LoadBalancer IP

## Supported DNS Providers

This chart supports automatic TLS certificate issuance via DNS-01 challenges with the following providers:

- **Scaleway DNS** - Requires webhook from `https://helm.scw.cloud/`
- **Gandi LiveDNS v5** - WIP  Requires webhook from `https://bwolf.github.io/cert-manager-webhook-gandi`
- **AWS Route53** - Native cert-manager support (no webhook required)

## Configuration

### Scaleway DNS

```yaml
acme:
  enabled: true
  email: admin@example.com
  production: true  # false for staging/testing
  rootHost: example.com
  provider: scaleway
  
  scaleway:
    accessKey: "SCWXXXXXXXXXXXXXXXXX"
    secretKey: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    # Or reference existing secret
    existingSecretName: scaleway-dns-credentials
    existingSecretAccessKeyKey: SCW_ACCESS_KEY
    existingSecretSecretKeyKey: SCW_SECRET_KEY
```

Required API permissions: `DNSFullAccess` or `DNSZonesRead` + `DNSRecordsWrite`

### Gandi LiveDNS v5

```yaml
acme:
  enabled: true
  email: admin@example.com
  production: true
  rootHost: example.com
  provider: gandi
  
  gandi:
    personalAccessToken: "your-gandi-pat-token"
    # Or reference existing secret
    existingSecretName: gandi-pat-secret
    existingSecretKey: api-token
```

Required permissions: "Manage domain name technical configurations"

### AWS Route53

```yaml
acme:
  enabled: true
  email: admin@example.com
  production: true
  rootHost: example.com
  provider: route53
  
  route53:
    region: eu-west-3
    accessKeyId: "AKIAXXXXX"
    secretAccessKey: "secret"
    hostedZoneId: "Z1234567890ABC"
```

Required IAM permissions: `route53:ChangeResourceRecordSets`, `route53:GetChange`, `route53:ListHostedZonesByName`

## How it works

1. **ClusterIssuer**: Created automatically for the selected DNS provider
2. **Certificate**: Generates wildcard certificate (`*.rootHost` + `rootHost`)
3. **Secret**: Stored as `<release-name>-ps-wildcard-tls`
4. **Ingress**: Automatically references the certificate via `ingress.tls.wildcard.externalSecretName`
5. **Renewal**: Automatic, 30 days before expiration (90-day validity)

## Verification

```bash
# Check ClusterIssuer status
kubectl get clusterissuer

# Check Certificate status
kubectl get certificate -n <namespace>

# Verify TLS secret exists
kubectl get secret <release-name>-ps-wildcard-tls -n <namespace>

# View certificate details
kubectl describe certificate <release-name>-ps-wildcard-certificate -n <namespace>
```

## Troubleshooting

### Debug certificate issuance

```bash
# Check ClusterIssuer
kubectl describe clusterissuer letsencrypt-<provider>

# Check Certificate status
kubectl describe certificate <cert-name> -n <namespace>

# Check DNS-01 challenges
kubectl get challenges -n <namespace>
kubectl describe challenge <challenge-name> -n <namespace>

# Check webhook logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=<webhook-name> --tail=100

# Check cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager --tail=100
```

### Common issues

**Certificate stuck in pending:**
- Verify API credentials have DNS write permissions
- Check webhook is running: `kubectl get pods -n cert-manager`
- Verify DNS propagation: `dig _acme-challenge.yourdomain.com TXT`
- Check for DNS-01 challenge errors in certificate events

**403 Forbidden errors:**
- API credentials lack required DNS permissions
- Verify credentials are correctly configured in the secret

**Email forbidden domain error:**
- Change `acme.email` to a valid email address (not example.com)

### Staging vs Production

Use staging environment for testing to avoid rate limits:

```yaml
acme:
  production: false  # Staging environment
```

Switch to production when ready:

```yaml
acme:
  production: true  # Production Let's Encrypt
```

After changing, force certificate renewal:

```bash
# Delete certificate and secret
kubectl delete certificate <cert-name> -n <namespace>
kubectl delete secret <secret-name> -n <namespace>

# Monitor renewal
kubectl get certificate -n <namespace> -w
```

## Certificate automatic renewal

cert-manager automatically handles certificate renewal:

- **Renewal timing**: Certificates are renewed **30 days before expiration** (Let's Encrypt certificates are valid for 90 days)
- **Automatic process**: No manual intervention required
- **Zero downtime**: New certificate is issued and the secret is updated atomically

**Verify automatic renewal is configured:**
```bash
# Check certificate details
kubectl describe certificate <certificate-name> -n <namespace>

# Look for:
# - Renewal Time: Should show a date ~30 days before expiration
# - Status Conditions: Should show "Ready=True"
```

**Check renewal history:**
```bash
# View certificate events
kubectl get events -n <namespace> --field-selector involvedObject.name=<certificate-name>

# Check cert-manager controller logs
kubectl logs -n cert-manager deploy/cert-manager -f | grep renewal
```

**Manually trigger renewal (for testing):**

There are multiple ways to force certificate renewal without redeploying the application:

```bash
# Method 1: Delete only the secret (recommended, fastest)
# The Certificate resource remains, cert-manager detects missing secret and renews
kubectl delete secret <secret-name> -n <namespace>

# Watch certificate being recreated (1-2 minutes)
kubectl get certificate -n <namespace> -w

# Method 2: Annotate the certificate to force renewal
kubectl annotate certificate <certificate-name> -n <namespace> \
  cert-manager.io/issue-temporary-certificate="true" --overwrite

# Method 3: Delete both certificate and secret
# Requires Helm chart to be installed (will recreate from template)
kubectl delete certificate <certificate-name> -n <namespace>
kubectl delete secret <secret-name> -n <namespace>

# Helm will recreate the Certificate resource automatically on next reconciliation
# Or manually trigger with: helm upgrade --reuse-values
```

**Monitor renewal notifications:**
- Configure email notifications via `acme.email` to receive expiration warnings
- Let's Encrypt sends emails at 20, 10, and 1 days before expiration (if auto-renewal fails)

## Migration from manual TLS configuration

If you were using manual TLS secrets:

```yaml
# Old (manual)
ingress:
  tls:
    wildcard:
      enabled: true
      externalSecretName: my-manual-cert

# New (automatic with cert-manager)
acme:
  enabled: true
  email: admin@example.com
  production: true
  rootHost: phrasea.cloud
  provider: scaleway
  scaleway:
    accessKey: "SCW..."
    secretKey: "..."

ingress:
  tls:
    wildcard:
      enabled: true
      externalSecretName: phrasea-ps-wildcard-tls  # Reference cert-manager generated secret
```

## Nginx Ingress integration

All Ingress resources are automatically configured with:
- `ingressClassName: nginx`
- TLS enabled with wildcard certificate
- Automatic certificate renewal handled by cert-manager

No additional annotations required.
